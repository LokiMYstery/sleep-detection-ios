import AVFoundation
import AudioToolbox
import CoreMotion
import Foundation
import UIKit
import WatchConnectivity
#if canImport(HealthKit)
import HealthKit
#endif

// MARK: - Types

struct SensorWindowSnapshot: Sendable {
    var motion: MotionFeatures?
    var audio: AudioFeatures?
    var interaction: InteractionFeatures?
    var watch: WatchFeatures?
    var physiology: PhysiologyFeatures? = nil
}

struct WatchProviderDiagnostic: Sendable {
    var event: RouteEvent
}

// MARK: - Protocols

protocol SensorProvider: AnyObject, Sendable {
    var providerId: String { get }
    func start(session: Session) throws
    func stop()
    func currentWindow() -> SensorWindowSnapshot?
}

protocol AudioProvider: SensorProvider {
    func consumeWindow(windowDuration: TimeInterval) -> AudioFeatures?
    func runtimeSnapshot() -> AudioRuntimeSnapshot
    func ensureRunning(reason: String)
    func setBundledPlaybackEnabled(_ enabled: Bool)
}

protocol WatchProvider: SensorProvider {
    func prepareRuntime(sessionId: UUID) throws
    func refreshDesiredRuntimeLease()
    func drainPendingWindows() -> [FeatureWindow]
    func runtimeSnapshot() -> WatchRuntimeSnapshot
    func drainDiagnostics() -> [WatchProviderDiagnostic]
}

// MARK: - Error Types

enum SensorProviderError: LocalizedError {
    case motionUnavailable
    case audioSessionFailed(Error)
    case audioEngineStartFailed(Error)
    case microphonePermissionDenied
    case watchSessionNotActivated

    var errorDescription: String? {
        switch self {
        case .motionUnavailable:
            return "Motion sensors are not available on this device"
        case .audioSessionFailed(let error):
            return "Failed to configure audio session: \(error.localizedDescription)"
        case .audioEngineStartFailed(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        case .microphonePermissionDenied:
            return "Microphone permission was denied"
        case .watchSessionNotActivated:
            return "Watch session could not be activated"
        }
    }
}

// MARK: - Placeholder Providers

final class PlaceholderAudioProvider: AudioProvider, @unchecked Sendable {
    let providerId = "audio.placeholder"

    func start(session: Session) throws {}
    func stop() {}
    func currentWindow() -> SensorWindowSnapshot? { nil }
    func consumeWindow(windowDuration: TimeInterval) -> AudioFeatures? { nil }
    func runtimeSnapshot() -> AudioRuntimeSnapshot { .inactive }
    func ensureRunning(reason: String) {}
    func setBundledPlaybackEnabled(_ enabled: Bool) {}
}

final class PlaceholderWatchProvider: WatchProvider, @unchecked Sendable {
    let providerId = "watch.placeholder"

    func start(session: Session) throws {}
    func prepareRuntime(sessionId: UUID) throws {}
    func refreshDesiredRuntimeLease() {}
    func stop() {}
    func currentWindow() -> SensorWindowSnapshot? { nil }
    func drainPendingWindows() -> [FeatureWindow] { [] }
    func runtimeSnapshot() -> WatchRuntimeSnapshot { .unavailable }
    func drainDiagnostics() -> [WatchProviderDiagnostic] { [] }
}

final class HealthKitHistoryProvider: SensorProvider, @unchecked Sendable {
    let providerId = "healthkit.history"

    func start(session: Session) throws {}
    func stop() {}
    func currentWindow() -> SensorWindowSnapshot? { nil }
}

// MARK: - Live Watch Provider

final class LiveWatchProvider: NSObject, WatchProvider, @unchecked Sendable {
    let providerId = "watch.live"

    private struct ProtectedState: Sendable {
        var activeSessionId: UUID?
        var desiredRuntime: WatchDesiredRuntimePayload?
        var nextDesiredRuntimeRevision = 0
        var pendingWindows: [FeatureWindow] = []
        var deliveredWindowKeys: Set<String> = []
        var heartRateSamples: [WatchWindowPayload.HRSample] = []
        var latestWatch: WatchFeatures?
        var pendingCommand: WatchSyncCommand?
        var diagnostics: [WatchProviderDiagnostic] = []
        var currentRuntime = WatchRuntimeSnapshot(
            isSupported: WCSession.isSupported(),
            isPaired: false,
            isWatchAppInstalled: false,
            isReachable: false,
            activationState: .notActivated,
            runtimeState: .idle,
            transportMode: .idle,
            lastCommandAt: nil,
            lastAckAt: nil,
            lastWindowAt: nil,
            lastError: nil,
            pendingWindowCount: 0
        )
    }

    private let protectedState: ThreadSafeBox<ProtectedState>
    private let systemTransportEnabled: Bool
    private let pendingCommandTransfers: ThreadSafeBox<[WCSessionUserInfoTransfer]>
    #if canImport(HealthKit)
    private let healthStore: HKHealthStore
    private let mirroredSession: ThreadSafeBox<HKWorkoutSession?>
    #endif

    private lazy var session: WCSession? = {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }()

    override init() {
        self.systemTransportEnabled = true
        self.protectedState = ThreadSafeBox(ProtectedState())
        self.pendingCommandTransfers = ThreadSafeBox([])
        #if canImport(HealthKit)
        self.healthStore = HKHealthStore()
        self.mirroredSession = ThreadSafeBox(nil)
        #endif
        super.init()
        configureSystemBindings()
    }

    init(systemTransportEnabled: Bool) {
        self.systemTransportEnabled = systemTransportEnabled
        self.protectedState = ThreadSafeBox(ProtectedState())
        self.pendingCommandTransfers = ThreadSafeBox([])
        #if canImport(HealthKit)
        self.healthStore = HKHealthStore()
        self.mirroredSession = ThreadSafeBox(nil)
        #endif
        super.init()
        configureSystemBindings()
    }

    private func configureSystemBindings() {
        guard systemTransportEnabled else {
            appendDiagnostic(stage: "provider.configure", message: "LiveWatchProvider initialized with system transport disabled")
            refreshRuntimeSnapshot()
            return
        }
        appendDiagnostic(stage: "provider.configure", message: "Activating WCSession and configuring mirroring handler")
        session?.delegate = self
        session?.activate()
        configureMirroringHandler()
        refreshRuntimeSnapshot()
    }

    func start(session: Session) throws {
        let desiredRuntime = nextDesiredRuntime(
            mode: .recording,
            sessionId: session.sessionId,
            sessionStartTime: session.startTime,
            sessionDuration: 12 * 60 * 60,
            preferredWindowDuration: 60
        )
        let command = makeCommand(
            kind: .startSession,
            sessionId: session.sessionId,
            sessionStartTime: session.startTime,
            requestedAt: desiredRuntime.requestedAt
        )

        appendDiagnostic(
            stage: "provider.start",
            message: "Starting live watch session bootstrap",
            extra: [
                "sessionId": session.sessionId.uuidString,
                "sessionStartTime": session.startTime.ISO8601Format(),
                "preferredWindowDurationSec": "\(Int(command.preferredWindowDuration))",
                "desiredRevision": "\(desiredRuntime.revision)"
            ]
        )

        protectedState.write { state in
            state.activeSessionId = session.sessionId
            state.desiredRuntime = desiredRuntime
            state.pendingWindows.removeAll()
            state.deliveredWindowKeys.removeAll()
            state.heartRateSamples.removeAll()
            state.latestWatch = nil
            state.pendingCommand = command
            state.currentRuntime.runtimeState = .launchRequested
            state.currentRuntime.transportMode = .bootstrap
            state.currentRuntime.lastCommandAt = desiredRuntime.requestedAt
            state.currentRuntime.lastAckAt = nil
            state.currentRuntime.lastWindowAt = nil
            state.currentRuntime.lastError = nil
            state.currentRuntime.pendingWindowCount = 0
            state.currentRuntime.activeSessionId = session.sessionId
            state.currentRuntime.ackedRevision = nil
            state.currentRuntime.leaseExpiresAt = desiredRuntime.leaseExpiresAt
        }
        #if canImport(HealthKit)
        mirroredSession.write { $0 = nil }
        #endif

        self.session?.delegate = self
        self.session?.activate()
        refreshRuntimeSnapshot()
        launchWatchAppForWorkout()
        transmit(desiredRuntime: desiredRuntime)
    }

    func prepareRuntime(sessionId: UUID) throws {
        let desiredRuntime = nextDesiredRuntime(
            mode: .prepared,
            sessionId: sessionId,
            sessionStartTime: nil,
            sessionDuration: 0,
            preferredWindowDuration: 0
        )
        let command = makeCommand(
            kind: .prepareRuntime,
            sessionId: sessionId,
            sessionStartTime: desiredRuntime.requestedAt,
            requestedAt: desiredRuntime.requestedAt
        )

        appendDiagnostic(
            stage: "provider.prepare",
            message: "Preparing watch runtime before realtime collection",
            extra: [
                "sessionId": sessionId.uuidString,
                "desiredRevision": "\(desiredRuntime.revision)"
            ]
        )

        protectedState.write { state in
            state.activeSessionId = sessionId
            state.desiredRuntime = desiredRuntime
            state.pendingCommand = command
            state.currentRuntime.runtimeState = .launchRequested
            state.currentRuntime.transportMode = .bootstrap
            state.currentRuntime.lastCommandAt = desiredRuntime.requestedAt
            state.currentRuntime.lastAckAt = nil
            state.currentRuntime.lastError = nil
            state.currentRuntime.activeSessionId = sessionId
            state.currentRuntime.ackedRevision = nil
            state.currentRuntime.leaseExpiresAt = desiredRuntime.leaseExpiresAt
        }

        self.session?.delegate = self
        self.session?.activate()
        refreshRuntimeSnapshot()
        launchWatchAppForWorkout()
        transmit(desiredRuntime: desiredRuntime)
    }

    func stop() {
        let currentSessionId: UUID? = protectedState.withLock { state in
            let id = state.activeSessionId ?? state.desiredRuntime?.sessionId
            state.latestWatch = nil
            state.heartRateSamples.removeAll()
            return id
        }

        guard let currentSessionId else {
            appendDiagnostic(stage: "provider.stop", message: "Stop requested with no active watch session")
            refreshRuntimeSnapshot()
            return
        }

        appendDiagnostic(
            stage: "provider.stop",
            message: "Stopping live watch session bootstrap",
            extra: [
                "sessionId": currentSessionId.uuidString
            ]
        )

        let desiredRuntime = nextDesiredRuntime(
            mode: .idle,
            sessionId: currentSessionId,
            sessionStartTime: nil,
            sessionDuration: 0,
            preferredWindowDuration: 0
        )
        protectedState.write { state in
            state.desiredRuntime = desiredRuntime
            state.pendingCommand = nil
            state.currentRuntime.runtimeState = .stopped
            state.currentRuntime.transportMode = .bootstrap
            state.currentRuntime.lastCommandAt = desiredRuntime.requestedAt
            state.currentRuntime.lastError = nil
            state.currentRuntime.activeSessionId = state.activeSessionId
            state.currentRuntime.leaseExpiresAt = desiredRuntime.leaseExpiresAt
        }
        transmit(desiredRuntime: desiredRuntime)
        #if canImport(HealthKit)
        mirroredSession.write { $0 = nil }
        #endif
        refreshRuntimeSnapshot()
    }

    func refreshDesiredRuntimeLease() {
        let desiredRuntime = protectedState.read { $0.desiredRuntime }
        guard let desiredRuntime else { return }

        let refreshedRuntime = nextDesiredRuntime(
            mode: desiredRuntime.mode,
            sessionId: desiredRuntime.sessionId,
            sessionStartTime: desiredRuntime.sessionStartTime,
            sessionDuration: desiredRuntime.sessionDuration,
            preferredWindowDuration: desiredRuntime.preferredWindowDuration
        )

        protectedState.write { state in
            state.desiredRuntime = refreshedRuntime
            state.currentRuntime.leaseExpiresAt = refreshedRuntime.leaseExpiresAt
            state.currentRuntime.activeSessionId = state.activeSessionId
        }

        transmit(desiredRuntime: refreshedRuntime)
        refreshRuntimeSnapshot()
    }

    func currentWindow() -> SensorWindowSnapshot? {
        let latestWatch = protectedState.withLock { $0.latestWatch }
        return SensorWindowSnapshot(
            motion: nil,
            audio: nil,
            interaction: nil,
            watch: latestWatch
        )
    }

    func drainPendingWindows() -> [FeatureWindow] {
        protectedState.withLock { state in
            let drained = state.pendingWindows.sorted { lhs, rhs in
                if lhs.endTime == rhs.endTime {
                    return lhs.windowId < rhs.windowId
                }
                return lhs.endTime < rhs.endTime
            }
            state.pendingWindows.removeAll()
            state.currentRuntime.pendingWindowCount = 0
            return drained
        }
    }

    func runtimeSnapshot() -> WatchRuntimeSnapshot {
        refreshRuntimeSnapshot()
        return protectedState.withLock { $0.currentRuntime }
    }

    func drainDiagnostics() -> [WatchProviderDiagnostic] {
        protectedState.withLock { state in
            let drained = state.diagnostics
            state.diagnostics.removeAll()
            return drained
        }
    }

    private func transmit(command: WatchSyncCommand) {
        appendDiagnostic(
            stage: "transmit.command",
            message: "Queueing watch command",
            extra: [
                "command": command.command.rawValue,
                "sessionId": command.sessionId.uuidString
            ]
        )
        let envelope = WatchTransportEnvelope.commandEnvelope(command)
        transmitViaWCSession(envelope, updateApplicationContext: true)
    }

    private func transmit(desiredRuntime: WatchDesiredRuntimePayload) {
        appendDiagnostic(
            stage: "transmit.desiredRuntime",
            message: "Publishing desired watch runtime",
            extra: [
                "mode": desiredRuntime.mode.rawValue,
                "revision": "\(desiredRuntime.revision)",
                "sessionId": desiredRuntime.sessionId?.uuidString ?? ""
            ]
        )
        let envelope = WatchTransportEnvelope.desiredRuntimeEnvelope(desiredRuntime)
        transmitViaWCSession(envelope, updateApplicationContext: true)
    }

    private func makeCommand(
        kind: WatchSyncCommand.Command,
        sessionId: UUID,
        sessionStartTime: Date,
        requestedAt: Date = Date()
    ) -> WatchSyncCommand {
        return WatchSyncCommand(
            command: kind,
            sessionId: sessionId,
            sessionStartTime: sessionStartTime,
            requestedAt: requestedAt,
            sessionDuration: kind == .startSession ? 12 * 60 * 60 : 0,
            preferredWindowDuration: kind == .startSession ? 60 : 0
        )
    }

    private func nextDesiredRuntime(
        mode: WatchDesiredRuntimePayload.Mode,
        sessionId: UUID?,
        sessionStartTime: Date?,
        sessionDuration: TimeInterval,
        preferredWindowDuration: TimeInterval
    ) -> WatchDesiredRuntimePayload {
        protectedState.withLock { state in
            state.nextDesiredRuntimeRevision += 1
            return WatchDesiredRuntimePayload(
                mode: mode,
                revision: state.nextDesiredRuntimeRevision,
                sessionId: sessionId,
                sessionStartTime: sessionStartTime,
                requestedAt: Date(),
                leaseExpiresAt: Date().addingTimeInterval(30),
                sessionDuration: sessionDuration,
                preferredWindowDuration: preferredWindowDuration
            )
        }
    }

    private func flushPendingCommandIfPossible() {
        guard let session else {
            appendDiagnostic(stage: "transmit.flushPending", message: "No WCSession instance available")
            return
        }
        guard session.activationState == .activated else {
            appendDiagnostic(
                stage: "transmit.flushPending",
                message: "Pending command cannot flush because WCSession is not activated",
                extra: [
                    "activationState": Self.activationState(from: session.activationState).rawValue
                ]
            )
            return
        }
        let (desiredRuntime, pendingCommand) = protectedState.withLock { state in
            (state.desiredRuntime, state.pendingCommand)
        }
        if let desiredRuntime {
            appendDiagnostic(
                stage: "transmit.flushPending",
                message: "Flushing desired runtime after WCSession activation change",
                extra: [
                    "mode": desiredRuntime.mode.rawValue,
                    "revision": "\(desiredRuntime.revision)"
                ]
            )
            transmit(desiredRuntime: desiredRuntime)
            return
        }
        guard let pendingCommand else { return }
        appendDiagnostic(
            stage: "transmit.flushPending",
            message: "Flushing pending command after WCSession activation change",
            extra: [
                "command": pendingCommand.command.rawValue
            ]
        )
        transmit(command: pendingCommand)
    }

    private func launchWatchAppForWorkout() {
        guard systemTransportEnabled else { return }
        #if canImport(HealthKit)
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown
        appendDiagnostic(
            stage: "launchWatchApp.request",
            message: "Requesting watch workout app launch",
            extra: [
                "activityType": "other",
                "locationType": "unknown"
            ]
        )
        healthStore.startWatchApp(with: configuration) { [weak self] success, error in
            self?.appendDiagnostic(
                stage: "launchWatchApp.completion",
                message: success ? "startWatchApp completed successfully" : "startWatchApp failed",
                extra: [
                    "success": String(success),
                    "error": error?.localizedDescription ?? ""
                ]
            )
            if !success, let error {
                self?.protectedState.write { state in
                    state.currentRuntime.lastError = error.localizedDescription
                }
            }
            self?.refreshRuntimeSnapshot()
        }
        #endif
    }

    private func configureMirroringHandler() {
        #if canImport(HealthKit)
        if #available(iOS 17.0, *) {
            appendDiagnostic(stage: "mirroring.handler", message: "Registering workoutSessionMirroringStartHandler")
            healthStore.workoutSessionMirroringStartHandler = { [weak self] mirroredSession in
                Task { @MainActor in
                    self?.appendDiagnostic(stage: "mirroring.handler", message: "Mirrored workout session received from watch")
                    self?.attachMirroredSession(mirroredSession)
                }
            }
        } else {
            appendDiagnostic(stage: "mirroring.handler", message: "Workout mirroring is unavailable below iOS 17")
        }
        #endif
    }

    @MainActor
    private func attachMirroredSession(_ mirroredSession: HKWorkoutSession) {
        mirroredSession.delegate = self
        #if canImport(HealthKit)
        self.mirroredSession.write { $0 = mirroredSession }
        #endif
        protectedState.write { state in
            state.currentRuntime.transportMode = .mirroredWorkoutSession
        }
        appendDiagnostic(stage: "mirroring.attach", message: "Attached mirrored HKWorkoutSession")
        refreshRuntimeSnapshot()
    }

    private func transmitViaWCSession(
        _ envelope: WatchTransportEnvelope,
        updateApplicationContext: Bool = false
    ) {
        guard systemTransportEnabled else {
            appendDiagnostic(stage: "wc.transmit", message: "System transport disabled; skipping WCSession transmit")
            return
        }
        guard let session else {
            appendDiagnostic(stage: "wc.transmit", message: "No WCSession instance available for transmit")
            return
        }
        guard let message = try? envelope.wcDictionary() else {
            appendDiagnostic(stage: "wc.transmit", message: "Failed to encode watch transport envelope")
            return
        }

        appendDiagnostic(
            stage: "wc.transmit",
            message: "Preparing WCSession transmit",
            extra: [
                "envelopeKind": envelope.kind.rawValue,
                "activationState": Self.activationState(from: session.activationState).rawValue,
                "isPaired": String(session.isPaired),
                "isWatchAppInstalled": String(session.isWatchAppInstalled),
                "isReachable": String(session.isReachable),
                "updateApplicationContext": String(updateApplicationContext)
            ]
        )

        if session.activationState == .activated {
            if updateApplicationContext {
                do {
                    try session.updateApplicationContext(message)
                    appendDiagnostic(stage: "wc.applicationContext", message: "Updated application context", extra: ["envelopeKind": envelope.kind.rawValue])
                } catch {
                    appendDiagnostic(
                        stage: "wc.applicationContext",
                        message: "Failed to update application context",
                        extra: [
                            "envelopeKind": envelope.kind.rawValue,
                            "error": error.localizedDescription
                        ]
                    )
                }
            }

            let shouldQueueTransferUserInfo: Bool
            switch envelope.kind {
            case .command:
                shouldQueueTransferUserInfo = !session.isReachable
            case .desiredRuntime:
                shouldQueueTransferUserInfo = false
            case .status, .window:
                shouldQueueTransferUserInfo = true
            }
            if shouldQueueTransferUserInfo {
                let transfer = session.transferUserInfo(message)
                if envelope.kind == .command {
                    pendingCommandTransfers.write { $0.append(transfer) }
                }
                appendDiagnostic(
                    stage: "wc.transferUserInfo",
                    message: "Queued transferUserInfo payload",
                    extra: [
                        "envelopeKind": envelope.kind.rawValue,
                        "outstandingTransfers": "\(session.outstandingUserInfoTransfers.count)"
                    ]
                )
            }

            if session.isReachable {
                appendDiagnostic(stage: "wc.sendMessage", message: "Sending interactive watch message", extra: ["envelopeKind": envelope.kind.rawValue])
                session.sendMessage(message, replyHandler: nil) { [weak self] error in
                    self?.appendDiagnostic(
                        stage: "wc.sendMessage",
                        message: "Interactive watch message failed",
                        extra: [
                            "envelopeKind": envelope.kind.rawValue,
                            "error": error.localizedDescription
                        ]
                    )
                    if envelope.kind == .command,
                       let retrySession = self?.session,
                       retrySession.activationState == .activated
                    {
                        let transfer = retrySession.transferUserInfo(message)
                        self?.pendingCommandTransfers.write { $0.append(transfer) }
                        self?.appendDiagnostic(
                            stage: "wc.transferUserInfo",
                            message: "Queued transferUserInfo fallback after interactive send failure",
                            extra: [
                                "envelopeKind": envelope.kind.rawValue,
                                "outstandingTransfers": "\(retrySession.outstandingUserInfoTransfers.count)"
                            ]
                        )
                    }
                    self?.refreshRuntimeSnapshot()
                }
            } else {
                appendDiagnostic(
                    stage: "wc.sendMessage",
                    message: "Skipped interactive watch message because watch is not reachable",
                    extra: ["envelopeKind": envelope.kind.rawValue]
                )
            }
        } else {
            appendDiagnostic(
                stage: "wc.transmit",
                message: "Skipped WCSession payload because session is not activated",
                extra: [
                    "envelopeKind": envelope.kind.rawValue,
                    "activationState": Self.activationState(from: session.activationState).rawValue
                ]
            )
        }

        refreshRuntimeSnapshot()
    }

    private func handle(status: WatchRuntimeStatusPayload, transportMode: WatchRuntimeSnapshot.TransportMode) {
        let currentSessionId: UUID? = protectedState.withLock { state in
            if state.activeSessionId == nil {
                state.activeSessionId = status.sessionId
            }
            return state.activeSessionId
        }
        guard status.sessionId == currentSessionId else {
            appendDiagnostic(
                stage: "incoming.status",
                message: "Ignored watch status for a different session",
                extra: [
                    "incomingSessionId": status.sessionId.uuidString,
                    "activeSessionId": currentSessionId?.uuidString ?? ""
                ]
            )
            return
        }

        let diagnosticEventType = status.details?["diagnosticEvent"]
        let diagnosticPayload = status.details?.filter { $0.key != "diagnosticEvent" } ?? [:]

        if shouldClearBootstrapArtifacts(for: status.state) {
            clearBootstrapArtifacts(for: status.sessionId)
        }

        protectedState.write { state in
            if let ackedRevision = status.ackedRevision {
                state.nextDesiredRuntimeRevision = max(state.nextDesiredRuntimeRevision, ackedRevision)
            }
            state.currentRuntime.runtimeState = status.state
            state.currentRuntime.transportMode = transportMode == .mirroredWorkoutSession
                ? .mirroredWorkoutSession
                : status.transportMode
            state.currentRuntime.ackedRevision = status.ackedRevision ?? state.currentRuntime.ackedRevision
            state.currentRuntime.leaseExpiresAt = status.leaseExpiresAt ?? state.currentRuntime.leaseExpiresAt
            state.currentRuntime.activeSessionId = state.activeSessionId
            if status.state == .commandReceived {
                state.currentRuntime.lastAckAt = status.occurredAt
                state.pendingCommand = nil
            }
            if status.state == .readyForRealtime {
                state.pendingCommand = nil
            }
            if status.state == .stopped {
                state.pendingCommand = nil
                state.activeSessionId = nil
                state.currentRuntime.activeSessionId = nil
                if state.desiredRuntime?.mode == .idle {
                    state.desiredRuntime = nil
                    state.currentRuntime.leaseExpiresAt = nil
                }
            }
            if let lastError = status.lastError {
                state.currentRuntime.lastError = lastError.isEmpty ? nil : lastError
            } else if status.state == .commandReceived ||
                        status.state == .readyForRealtime ||
                        status.state == .workoutStarted ||
                        status.state == .mirrorConnected ||
                        status.state == .stopped {
                state.currentRuntime.lastError = nil
            }
            if let diagnosticEventType {
                state.diagnostics.append(
                    WatchProviderDiagnostic(
                        event: RouteEvent(
                            routeId: .E,
                            eventType: diagnosticEventType,
                            payload: diagnosticPayload
                        )
                    )
                )
                if state.diagnostics.count > 400 {
                    state.diagnostics.removeFirst(state.diagnostics.count - 400)
                }
            }
        }

        appendDiagnostic(
            stage: "incoming.status",
            message: "Received watch runtime status",
            extra: [
                "runtimeState": status.state.rawValue,
                "transportMode": transportMode.rawValue,
                "statusTransportMode": status.transportMode.rawValue,
                "lastError": status.lastError ?? ""
            ]
        )

        refreshRuntimeSnapshot()
    }

    private func handle(payload: WatchWindowPayload, transportMode: WatchRuntimeSnapshot.TransportMode) {
        let currentSessionId: UUID? = protectedState.withLock { state in
            if state.activeSessionId == nil {
                state.activeSessionId = payload.sessionId
            }
            return state.activeSessionId
        }
        guard payload.sessionId == currentSessionId else {
            appendDiagnostic(
                stage: "incoming.window",
                message: "Ignored watch window for a different session",
                extra: [
                    "incomingSessionId": payload.sessionId.uuidString,
                    "activeSessionId": currentSessionId?.uuidString ?? "",
                    "windowId": "\(payload.windowId)"
                ]
            )
            return
        }
        let windowKey = "\(payload.sessionId.uuidString)-\(payload.windowId)-\(payload.endTime.timeIntervalSince1970)"
        var acceptedWindow = false

        clearBootstrapArtifacts(for: payload.sessionId)

        protectedState.write { state in
            guard !state.deliveredWindowKeys.contains(windowKey) else { return }
            state.deliveredWindowKeys.insert(windowKey)
            acceptedWindow = true

            let freshnessCutoff = payload.endTime.addingTimeInterval(-20 * 60)
            state.heartRateSamples.append(contentsOf: payload.heartRateSamples)
            state.heartRateSamples = deduplicated(samples: state.heartRateSamples)
                .filter { $0.timestamp >= freshnessCutoff }

            let heartRateTrend = Self.computeHeartRateTrend(
                samples: state.heartRateSamples,
                endTime: payload.endTime
            )
            let watchFeatures = WatchFeatures(
                wristAccelRMS: payload.wristAccelRMS,
                wristStillDuration: payload.wristStillDuration,
                heartRate: payload.heartRate,
                heartRateTrend: heartRateTrend,
                dataQuality: payload.dataQuality,
                motionSignalVersion: payload.motionSignalVersion
            )

            state.latestWatch = watchFeatures
            state.currentRuntime.lastWindowAt = payload.sentAt
            state.currentRuntime.transportMode = transportMode
            state.pendingCommand = nil
            state.currentRuntime.activeSessionId = state.activeSessionId
            state.pendingWindows.append(
                FeatureWindow(
                    windowId: payload.windowId,
                    startTime: payload.startTime,
                    endTime: payload.endTime,
                    duration: payload.endTime.timeIntervalSince(payload.startTime),
                    source: .watch,
                    motion: nil,
                    audio: nil,
                    interaction: nil,
                    watch: watchFeatures
                )
            )
        }

        appendDiagnostic(
            stage: "incoming.window",
            message: acceptedWindow ? "Accepted watch feature window" : "Dropped duplicate watch feature window",
            extra: [
                "windowId": "\(payload.windowId)",
                "transportMode": transportMode.rawValue,
                "isBackfilled": String(payload.isBackfilled),
                "dataQuality": payload.dataQuality.rawValue,
                "heartRateSampleCount": "\(payload.heartRateSamples.count)"
            ]
        )

        refreshRuntimeSnapshot()
    }

    private func shouldClearBootstrapArtifacts(for state: WatchRuntimeSnapshot.RuntimeState) -> Bool {
        switch state {
        case .commandReceived,
             .authorizationRequired,
             .readyForRealtime,
             .workoutStarted,
             .workoutFailed,
             .mirrorConnected,
             .mirrorDisconnected,
             .stopped:
            return true
        case .idle, .launchRequested:
            return false
        }
    }

    private func clearBootstrapArtifacts(for sessionId: UUID) {
        pendingCommandTransfers.write { transfers in
            transfers.forEach { $0.cancel() }
            transfers.removeAll()
        }

        guard protectedState.withLock({ $0.desiredRuntime == nil }) else { return }
        guard systemTransportEnabled, let session, session.activationState == .activated else { return }
        let clearingStatus = WatchRuntimeStatusPayload(
            sessionId: sessionId,
            state: .commandReceived,
            occurredAt: Date(),
            transportMode: .bootstrap,
            lastError: nil
        )
        guard let dictionary = try? WatchTransportEnvelope.statusEnvelope(clearingStatus).wcDictionary() else { return }
        do {
            try session.updateApplicationContext(dictionary)
            appendDiagnostic(
                stage: "wc.applicationContext",
                message: "Cleared stale command application context after watch acknowledgement",
                extra: [
                    "sessionId": sessionId.uuidString
                ]
            )
        } catch {
            appendDiagnostic(
                stage: "wc.applicationContext",
                message: "Failed to clear stale command application context",
                extra: [
                    "sessionId": sessionId.uuidString,
                    "error": error.localizedDescription
                ]
            )
        }
    }

    private func handle(envelope: WatchTransportEnvelope, transportMode: WatchRuntimeSnapshot.TransportMode) {
        appendDiagnostic(
            stage: "incoming.envelope",
            message: "Received watch transport envelope",
            extra: [
                "kind": envelope.kind.rawValue,
                "transportMode": transportMode.rawValue
            ]
        )
        switch envelope.kind {
        case .command:
            refreshRuntimeSnapshot()
        case .desiredRuntime:
            appendDiagnostic(stage: "incoming.envelope", message: "Ignored desired runtime envelope on iPhone provider")
        case .status:
            guard let status = envelope.status else { return }
            handle(status: status, transportMode: transportMode)
        case .window:
            guard let payload = envelope.window else { return }
            handle(payload: payload, transportMode: transportMode)
        }
    }

    private func appendDiagnostic(
        stage: String,
        message: String,
        extra: [String: String] = [:]
    ) {
        protectedState.write { state in
            let snapshot = state.currentRuntime
            var payload: [String: String] = [
                "stage": stage,
                "message": message,
                "activationState": snapshot.activationState.rawValue,
                "runtimeState": snapshot.runtimeState.rawValue,
                "transportMode": snapshot.transportMode.rawValue,
                "isPaired": String(snapshot.isPaired),
                "isWatchAppInstalled": String(snapshot.isWatchAppInstalled),
                "isReachable": String(snapshot.isReachable),
                "pendingWindowCount": "\(snapshot.pendingWindowCount)"
            ]
            if let activeSessionId = state.activeSessionId {
                payload["activeSessionId"] = activeSessionId.uuidString
            }
            if let pendingCommand = state.pendingCommand {
                payload["pendingCommand"] = pendingCommand.command.rawValue
            }
            if let lastError = snapshot.lastError, !lastError.isEmpty {
                payload["lastError"] = lastError
            }
            for (key, value) in extra {
                payload[key] = value
            }
            state.diagnostics.append(
                WatchProviderDiagnostic(
                    event: RouteEvent(
                        routeId: .E,
                        eventType: "system.watchProviderLog",
                        payload: payload
                    )
                )
            )
            if state.diagnostics.count > 400 {
                state.diagnostics.removeFirst(state.diagnostics.count - 400)
            }
        }
    }

    private func refreshRuntimeSnapshot() {
        let activationState = Self.activationState(from: session?.activationState ?? .notActivated)
        protectedState.write { state in
            state.currentRuntime.isSupported = WCSession.isSupported()
            state.currentRuntime.isPaired = session?.isPaired ?? false
            state.currentRuntime.isWatchAppInstalled = session?.isWatchAppInstalled ?? false
            state.currentRuntime.isReachable = session?.isReachable ?? false
            state.currentRuntime.activationState = activationState
            state.currentRuntime.pendingWindowCount = state.pendingWindows.count
            state.currentRuntime.activeSessionId = state.activeSessionId
            if state.currentRuntime.leaseExpiresAt == nil {
                state.currentRuntime.leaseExpiresAt = state.desiredRuntime?.leaseExpiresAt
            }
        }
    }

    private static func activationState(from state: WCSessionActivationState) -> WatchRuntimeSnapshot.ActivationState {
        switch state {
        case .notActivated:
            .notActivated
        case .inactive:
            .inactive
        case .activated:
            .activated
        @unknown default:
            .notActivated
        }
    }

    private func deduplicated(samples: [WatchWindowPayload.HRSample]) -> [WatchWindowPayload.HRSample] {
        var seen: Set<String> = []
        return samples
            .sorted { $0.timestamp < $1.timestamp }
            .filter { sample in
                let key = "\(sample.timestamp.timeIntervalSince1970)-\(sample.bpm)"
                return seen.insert(key).inserted
            }
    }

    private static func computeHeartRateTrend(
        samples: [WatchWindowPayload.HRSample],
        endTime: Date
    ) -> WatchFeatures.HRTrend {
        let relevantSamples = samples
            .filter { $0.timestamp <= endTime && $0.timestamp >= endTime.addingTimeInterval(-20 * 60) }
            .sorted { $0.timestamp < $1.timestamp }

        guard relevantSamples.count >= 3 else { return .insufficient }

        let xValues = relevantSamples.map { $0.timestamp.timeIntervalSince(relevantSamples[0].timestamp) / 60 }
        let yValues = relevantSamples.map(\.bpm)
        let count = Double(relevantSamples.count)
        let sumX = xValues.reduce(0, +)
        let sumY = yValues.reduce(0, +)
        let sumXY = zip(xValues, yValues).reduce(0) { $0 + ($1.0 * $1.1) }
        let sumXX = xValues.reduce(0) { $0 + ($1 * $1) }
        let denominator = count * sumXX - sumX * sumX
        guard denominator != 0 else { return .insufficient }

        let slope = (count * sumXY - sumX * sumY) / denominator
        let meanY = sumY / count
        let intercept = (sumY - slope * sumX) / count
        let ssTot = yValues.reduce(0) { $0 + pow($1 - meanY, 2) }
        let ssRes = zip(xValues, yValues).reduce(0) { partial, pair in
            let predicted = intercept + slope * pair.0
            return partial + pow(pair.1 - predicted, 2)
        }
        let rSquared = ssTot == 0 ? 1 : max(0, 1 - (ssRes / ssTot))

        if slope <= -0.3, rSquared >= 0.2 {
            return .dropping
        }
        if slope >= 0.3 {
            return .rising
        }
        return .stable
    }
}

// MARK: - WCSessionDelegate

extension LiveWatchProvider: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        appendDiagnostic(
            stage: "wc.activationDidComplete",
            message: "WCSession activation completed",
            extra: [
                "activationState": Self.activationState(from: activationState).rawValue,
                "isPaired": String(session.isPaired),
                "isWatchAppInstalled": String(session.isWatchAppInstalled),
                "isReachable": String(session.isReachable),
                "error": error?.localizedDescription ?? ""
            ]
        )
        if let error {
            protectedState.write { $0.currentRuntime.lastError = error.localizedDescription }
        }
        refreshRuntimeSnapshot()
        flushPendingCommandIfPossible()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        appendDiagnostic(stage: "wc.inactive", message: "WCSession became inactive")
        refreshRuntimeSnapshot()
    }

    func sessionDidDeactivate(_ session: WCSession) {
        appendDiagnostic(stage: "wc.deactivate", message: "WCSession deactivated; re-activating")
        session.activate()
        refreshRuntimeSnapshot()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        appendDiagnostic(
            stage: "wc.reachability",
            message: "WCSession reachability changed",
            extra: [
                "isReachable": String(session.isReachable),
                "isWatchAppInstalled": String(session.isWatchAppInstalled)
            ]
        )
        refreshRuntimeSnapshot()
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        appendDiagnostic(stage: "wc.receiveApplicationContext", message: "Received application context from watch")
        handleIncoming(dictionary: applicationContext, transportMode: .bootstrap)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        appendDiagnostic(stage: "wc.receiveUserInfo", message: "Received userInfo payload from watch")
        handleIncoming(dictionary: userInfo, transportMode: .wcSessionFallback)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        appendDiagnostic(stage: "wc.receiveMessage", message: "Received interactive watch message")
        handleIncoming(dictionary: message, transportMode: .wcSessionFallback)
    }

    private func handleIncoming(dictionary: [String: Any], transportMode: WatchRuntimeSnapshot.TransportMode) {
        guard let envelope = try? WatchTransportEnvelope.decode(dictionary: dictionary) else {
            appendDiagnostic(stage: "incoming.decode", message: "Failed to decode watch transport payload", extra: ["transportMode": transportMode.rawValue])
            return
        }
        handle(envelope: envelope, transportMode: transportMode)
    }
}

#if canImport(HealthKit)
extension LiveWatchProvider: HKWorkoutSessionDelegate {
    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {}

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        protectedState.write { state in
            state.currentRuntime.runtimeState = .mirrorDisconnected
            state.currentRuntime.lastError = error.localizedDescription
            state.currentRuntime.transportMode = .wcSessionFallback
        }
        appendDiagnostic(
            stage: "mirroring.fail",
            message: "Mirrored workout session failed on iPhone; degrading to WC fallback",
            extra: [
                "error": error.localizedDescription
            ]
        )
        refreshRuntimeSnapshot()
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        appendDiagnostic(
            stage: "mirroring.receive",
            message: "Received mirrored workout data from watch",
            extra: [
                "payloadCount": "\(data.count)"
            ]
        )
        for envelopeData in data {
            guard let envelope = try? WatchTransportEnvelope.decode(data: envelopeData) else { continue }
            handle(envelope: envelope, transportMode: .mirroredWorkoutSession)
        }
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didDisconnectFromRemoteDeviceWithError error: (any Error)?
    ) {
        mirroredSession.write { currentSession in
            if currentSession === workoutSession {
                currentSession = nil
            }
        }
        protectedState.write { state in
            state.currentRuntime.runtimeState = .mirrorDisconnected
            state.currentRuntime.transportMode = .wcSessionFallback
            if let error {
                state.currentRuntime.lastError = error.localizedDescription
            }
        }
        appendDiagnostic(
            stage: "mirroring.disconnect",
            message: "Mirrored workout session disconnected",
            extra: [
                "error": error?.localizedDescription ?? ""
            ]
        )
        refreshRuntimeSnapshot()
    }
}
#endif

#if DEBUG
extension LiveWatchProvider {
    func debugPendingCommand() -> WatchSyncCommand? {
        protectedState.withLock { $0.pendingCommand }
    }

    func debugDesiredRuntime() -> WatchDesiredRuntimePayload? {
        protectedState.read { $0.desiredRuntime }
    }

    func debugInject(status: WatchRuntimeStatusPayload, transportMode: WatchRuntimeSnapshot.TransportMode = .wcSessionFallback) {
        handle(status: status, transportMode: transportMode)
    }

    func debugInject(window: WatchWindowPayload, transportMode: WatchRuntimeSnapshot.TransportMode = .mirroredWorkoutSession) {
        handle(payload: window, transportMode: transportMode)
    }
}
#endif

// MARK: - Live Motion Provider

final class LiveMotionProvider: SensorProvider, @unchecked Sendable {
    private struct MotionSample: Sendable {
        let timestamp: Date
        let accelerationMagnitude: Double
        let attitudeChangeRate: Double
    }

    let providerId = "motion.live"

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()

    // Use ThreadSafeArray instead of NSLock + array for better concurrency safety
    private let samples: ThreadSafeArray<MotionSample>
    private let lastAttitude: ThreadSafeBox<CMAttitude?>

    init(maxSamples: Int = 10000) {
        self.samples = ThreadSafeArray(maxSize: maxSamples)
        self.lastAttitude = ThreadSafeBox(nil)
        queue.name = "SleepDetectionPOC.motion-provider"
        queue.qualityOfService = .utility
    }

    func start(session: Session) throws {
        samples.removeAll()
        lastAttitude.write { $0 = nil }

        motionManager.deviceMotionUpdateInterval = 0.1
        guard motionManager.isDeviceMotionAvailable else {
            throw SensorProviderError.motionUnavailable
        }

        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let acceleration = motion.userAcceleration
            let magnitude = sqrt(
                pow(acceleration.x, 2) +
                pow(acceleration.y, 2) +
                pow(acceleration.z, 2)
            )

            let attitudeRate: Double
            if let previous = self.lastAttitude.value {
                let deltaPitch = motion.attitude.pitch - previous.pitch
                let deltaRoll = motion.attitude.roll - previous.roll
                attitudeRate = sqrt(deltaPitch * deltaPitch + deltaRoll * deltaRoll) * 57.2958 / 0.1
            } else {
                attitudeRate = 0
            }

            self.lastAttitude.write { $0 = motion.attitude.copy() as? CMAttitude }
            self.samples.append(
                MotionSample(
                    timestamp: Date(),
                    accelerationMagnitude: magnitude,
                    attitudeChangeRate: attitudeRate
                )
            )
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        samples.removeAll()
        lastAttitude.write { $0 = nil }
    }

    func currentWindow() -> SensorWindowSnapshot? {
        SensorWindowSnapshot(
            motion: aggregate(shouldDrain: false),
            audio: nil,
            interaction: nil,
            watch: nil
        )
    }

    func drainMotionFeatures(windowDuration: TimeInterval) -> MotionFeatures? {
        aggregate(shouldDrain: true, fallbackDuration: windowDuration)
    }

    private func aggregate(
        shouldDrain: Bool,
        fallbackDuration: TimeInterval = 30
    ) -> MotionFeatures? {
        let currentSamples: [MotionSample]
        if shouldDrain {
            currentSamples = samples.drain()
        } else {
            currentSamples = samples.allElements()
        }

        guard !currentSamples.isEmpty else { return nil }

        let magnitudes = currentSamples.map(\.accelerationMagnitude)
        let rms = sqrt(magnitudes.map { $0 * $0 }.reduce(0, +) / Double(magnitudes.count))
        let peakThreshold = 0.05
        let peaks = magnitudes.filter { $0 >= peakThreshold }.count
        let stillThreshold = 0.02
        let stillSamples = magnitudes.filter { $0 < stillThreshold }.count
        let stillRatio = Double(stillSamples) / Double(magnitudes.count)
        let stillDuration = fallbackDuration * stillRatio
        let attitudeRates = currentSamples.map(\.attitudeChangeRate)
        let attitudeAverage = attitudeRates.reduce(0, +) / Double(attitudeRates.count)

        return MotionFeatures(
            accelRMS: rms,
            peakCount: peaks,
            attitudeChangeRate: attitudeAverage,
            maxAccel: magnitudes.max() ?? 0,
            stillRatio: stillRatio,
            stillDuration: stillDuration
        )
    }
}

// MARK: - Live Interaction Provider

final class LiveInteractionProvider: SensorProvider, @unchecked Sendable {
    let providerId = "interaction.live"

    // Use ThreadSafeBox for thread-safe state access
    private struct ProtectedState: Sendable {
        var isMonitoring = false
        var isLocked = false
        var lastInteractionAt: Date?
        var screenWakeCount = 0
    }

    private let protectedState: ThreadSafeBox<ProtectedState>
    private var observationTokens: [NSObjectProtocol] = []
    private let observationQueue = DispatchQueue(label: "SleepDetectionPOC.interaction-observer")

    init() {
        self.protectedState = ThreadSafeBox(ProtectedState())
    }

    func start(session: Session) throws {
        guard !protectedState.value.isMonitoring else { return }

        protectedState.write { state in
            state.isMonitoring = true
            state.lastInteractionAt = session.startTime
            state.screenWakeCount = 0
            state.isLocked = false
        }

        let center = NotificationCenter.default
        observationTokens = [
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.observationQueue.async {
                    self?.protectedState.write { state in
                        state.screenWakeCount += 1
                        state.isLocked = false
                    }
                }
            },
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.observationQueue.async {
                    self?.protectedState.write { state in
                        state.isLocked = true
                    }
                }
            },
            center.addObserver(
                forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.observationQueue.async {
                    self?.protectedState.write { state in
                        state.isLocked = true
                    }
                }
            },
            center.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.observationQueue.async {
                    self?.protectedState.write { state in
                        state.isLocked = false
                    }
                }
            }
        ]
    }

    func stop() {
        observationTokens.forEach(NotificationCenter.default.removeObserver)
        observationTokens.removeAll()

        protectedState.write { state in
            state.isMonitoring = false
            state.screenWakeCount = 0
        }
    }

    func currentWindow() -> SensorWindowSnapshot? {
        let state = protectedState.value
        return SensorWindowSnapshot(
            motion: nil,
            audio: nil,
            interaction: snapshot(from: state, now: Date()),
            watch: nil
        )
    }

    func markInteraction(at date: Date = Date()) {
        protectedState.write { state in
            state.lastInteractionAt = date
            state.isLocked = false
        }
    }

    func consumeWindow(now: Date) -> InteractionFeatures {
        let state = protectedState.value
        let features = snapshot(from: state, now: now)

        protectedState.write { state in
            state.screenWakeCount = 0
        }

        return features
    }

    private func snapshot(from state: ProtectedState, now: Date) -> InteractionFeatures {
        let sinceLastInteraction = now.timeIntervalSince(state.lastInteractionAt ?? now)
        return InteractionFeatures(
            isLocked: state.isLocked,
            timeSinceLastInteraction: sinceLastInteraction,
            screenWakeCount: state.screenWakeCount,
            lastInteractionAt: state.lastInteractionAt
        )
    }
}

// MARK: - Live Audio Provider

final class LiveAudioProvider: AudioProvider, @unchecked Sendable {
    enum AudioCaptureBackendKind: String, Sendable {
        case voiceProcessingIOFullDuplex
    }

    enum AudioSessionStrategyKind: String, Sendable {
        case voiceChatFullDuplex

        var category: AVAudioSession.Category { .playAndRecord }

        var mode: AVAudioSession.Mode { .voiceChat }

        var categoryOptions: AVAudioSession.CategoryOptions { [.defaultToSpeaker] }

        var prefersEchoCancelledInput: Bool { true }
    }

    private final class BundledPlaybackController: @unchecked Sendable {
        struct Snapshot: Sendable {
            var available: Bool
            var enabled: Bool
            var assetName: String?
            var error: String?
        }

        private let lock = NSLock()
        private let resourceName: String
        private let fileExtension: String
        private let assetName: String
        private var loadedSampleRate: Double?
        private var samples: [Float] = []
        private var nextSampleIndex = 0
        private var isEnabled = false
        private var lastError: String?

        init(resourceName: String, fileExtension: String) {
            self.resourceName = resourceName
            self.fileExtension = fileExtension
            self.assetName = "\(resourceName).\(fileExtension)"
        }

        private func withLock<R>(_ operation: () -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return operation()
        }

        func prepareIfNeeded(outputFormat: AVAudioFormat) {
            let targetSampleRate = outputFormat.sampleRate
            let shouldLoad = withLock { () -> Bool in
                if !samples.isEmpty, loadedSampleRate == targetSampleRate {
                    return false
                }
                return true
            }
            guard shouldLoad else { return }

            do {
                let decodedSamples = try Self.decodeLoopableSamples(
                    resourceName: resourceName,
                    fileExtension: fileExtension,
                    outputFormat: outputFormat
                )
                withLock {
                    samples = decodedSamples
                    loadedSampleRate = targetSampleRate
                    nextSampleIndex = 0
                    lastError = nil
                    if decodedSamples.isEmpty {
                        isEnabled = false
                    }
                }
            } catch {
                withLock {
                    samples = []
                    loadedSampleRate = nil
                    nextSampleIndex = 0
                    isEnabled = false
                    lastError = error.localizedDescription
                }
            }
        }

        func setEnabled(_ enabled: Bool) {
            withLock {
                if enabled, !samples.isEmpty {
                    isEnabled = true
                } else {
                    isEnabled = false
                    nextSampleIndex = 0
                }
            }
        }

        func stop() {
            setEnabled(false)
        }

        func fillOutput(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
            guard frameCount > 0 else { return }

            lock.lock()
            let shouldPlay = isEnabled && !samples.isEmpty
            if !shouldPlay {
                lock.unlock()
                memset(buffer, 0, frameCount * MemoryLayout<Float>.size)
                return
            }

            let sampleCount = samples.count
            samples.withUnsafeBufferPointer { sampleBuffer in
                guard let sourceBaseAddress = sampleBuffer.baseAddress else { return }
                var remaining = frameCount
                var writePointer = buffer

                while remaining > 0 {
                    if nextSampleIndex >= sampleCount {
                        nextSampleIndex = 0
                    }
                    let copyCount = min(remaining, sampleCount - nextSampleIndex)
                    memcpy(
                        writePointer,
                        sourceBaseAddress.advanced(by: nextSampleIndex),
                        copyCount * MemoryLayout<Float>.size
                    )
                    writePointer = writePointer.advanced(by: copyCount)
                    remaining -= copyCount
                    nextSampleIndex += copyCount
                }
            }
            lock.unlock()
        }

        func snapshot() -> Snapshot {
            withLock {
                Snapshot(
                    available: !samples.isEmpty,
                    enabled: isEnabled && !samples.isEmpty,
                    assetName: assetName,
                    error: lastError
                )
            }
        }

        private static func decodeLoopableSamples(
            resourceName: String,
            fileExtension: String,
            outputFormat: AVAudioFormat
        ) throws -> [Float] {
            guard let resourceURL = Bundle.main.url(forResource: resourceName, withExtension: fileExtension) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "Bundled playback asset \(resourceName).\(fileExtension) was not found in the app bundle"
                ])
            }

            let sourceFile = try AVAudioFile(forReading: resourceURL)
            let sourceFormat = sourceFile.processingFormat
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: outputFormat.sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                throw CocoaError(.coderInvalidValue, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to construct target playback format"
                ])
            }

            let sourceFrameCapacity = AVAudioFrameCount(min(sourceFile.length, Int64(UInt32.max)))
            guard sourceFrameCapacity > 0 else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "Bundled playback asset \(resourceName).\(fileExtension) is empty"
                ])
            }

            guard let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: sourceFrameCapacity
            ) else {
                throw CocoaError(.coderInvalidValue, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to allocate source buffer for bundled playback asset"
                ])
            }
            try sourceFile.read(into: sourceBuffer)

            if
                sourceFormat.channelCount == targetFormat.channelCount,
                sourceFormat.sampleRate == targetFormat.sampleRate,
                sourceFormat.commonFormat == .pcmFormatFloat32,
                !sourceFormat.isInterleaved,
                let channelData = sourceBuffer.floatChannelData?.pointee
            {
                let frameLength = Int(sourceBuffer.frameLength)
                guard frameLength > 0 else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [
                        NSLocalizedDescriptionKey: "Bundled playback asset \(resourceName).\(fileExtension) decoded to zero frames"
                    ])
                }
                return Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            }

            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw CocoaError(.coderInvalidValue, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create audio converter for bundled playback asset"
                ])
            }

            let capacityRatio = targetFormat.sampleRate / max(sourceFormat.sampleRate, 1)
            let targetFrameCapacity = AVAudioFrameCount(
                ceil(Double(sourceBuffer.frameLength) * capacityRatio)
            ) + 1024
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: max(targetFrameCapacity, 2048)
            ) else {
                throw CocoaError(.coderInvalidValue, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to allocate converted buffer for bundled playback asset"
                ])
            }

            var didProvideInput = false
            var conversionError: NSError?
            let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                didProvideInput = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }

            if let conversionError {
                throw conversionError
            }
            guard status == .haveData || status == .endOfStream || status == .inputRanDry else {
                throw CocoaError(.coderReadCorrupt, userInfo: [
                    NSLocalizedDescriptionKey: "Bundled playback asset conversion returned \(status.rawValue)"
                ])
            }
            guard
                let convertedChannelData = convertedBuffer.floatChannelData?.pointee,
                convertedBuffer.frameLength > 0
            else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "Bundled playback asset \(resourceName).\(fileExtension) converted to zero frames"
                ])
            }

            return Array(UnsafeBufferPointer(
                start: convertedChannelData,
                count: Int(convertedBuffer.frameLength)
            ))
        }
    }

    private final class VoiceProcessingCaptureBackend: @unchecked Sendable {
        private static let inputBus: UInt32 = 1
        private static let outputBus: UInt32 = 0

        private static let inputCallback: AURenderCallback = { refCon, ioActionFlags, timeStamp, busNumber, frameCount, _ in
            let backend = Unmanaged<VoiceProcessingCaptureBackend>.fromOpaque(refCon).takeUnretainedValue()
            return backend.handleInput(
                ioActionFlags: ioActionFlags,
                timeStamp: timeStamp,
                busNumber: busNumber,
                frameCount: frameCount
            )
        }

        private static let outputCallback: AURenderCallback = { refCon, ioActionFlags, timeStamp, busNumber, frameCount, ioData in
            let backend = Unmanaged<VoiceProcessingCaptureBackend>.fromOpaque(refCon).takeUnretainedValue()
            return backend.handleOutput(
                ioActionFlags: ioActionFlags,
                timeStamp: timeStamp,
                busNumber: busNumber,
                frameCount: frameCount,
                ioData: ioData
            )
        }

        private let captureFormat: AVAudioFormat
        private let bufferHandler: @Sendable (AVAudioPCMBuffer) -> Void
        private let playbackRenderer: @Sendable (UnsafeMutablePointer<Float>, Int) -> Void
        private let outputHandler: @Sendable () -> Void
        private let errorHandler: @Sendable (String) -> Void
        private var audioUnit: AudioUnit?
        private var scratchBuffer: UnsafeMutablePointer<Float>?
        private var scratchFrameCapacity: UInt32 = 0
        private var outputScratchBuffer: UnsafeMutablePointer<Float>?
        private var outputScratchFrameCapacity: UInt32 = 0

        init(
            captureFormat: AVAudioFormat,
            bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
            playbackRenderer: @escaping @Sendable (UnsafeMutablePointer<Float>, Int) -> Void,
            outputHandler: @escaping @Sendable () -> Void,
            errorHandler: @escaping @Sendable (String) -> Void
        ) {
            self.captureFormat = captureFormat
            self.bufferHandler = bufferHandler
            self.playbackRenderer = playbackRenderer
            self.outputHandler = outputHandler
            self.errorHandler = errorHandler
        }

        var isRunning: Bool {
            audioUnit != nil
        }

        func start() throws {
            stop()

            let streamDescription = captureFormat.streamDescription.pointee

            var description = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )

            guard let component = AudioComponentFindNext(nil, &description) else {
                let error = CocoaError(.featureUnsupported, userInfo: [
                    NSLocalizedDescriptionKey: "VoiceProcessingIO component is unavailable"
                ])
                throw SensorProviderError.audioEngineStartFailed(error)
            }

            var newAudioUnit: AudioComponentInstance?
            try Self.checkStatus(
                AudioComponentInstanceNew(component, &newAudioUnit),
                description: "Failed to instantiate VoiceProcessingIO"
            )
            guard let audioUnit = newAudioUnit else {
                let error = CocoaError(.coderInvalidValue, userInfo: [
                    NSLocalizedDescriptionKey: "VoiceProcessingIO component instance was nil"
                ])
                throw SensorProviderError.audioEngineStartFailed(error)
            }

            do {
                var enableInput: UInt32 = 1
                var enableOutput: UInt32 = 1
                var inputFormat = streamDescription
                var outputFormat = streamDescription
                var inputCallback = AURenderCallbackStruct(
                    inputProc: Self.inputCallback,
                    inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
                )
                var outputCallback = AURenderCallbackStruct(
                    inputProc: Self.outputCallback,
                    inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
                )

                try Self.checkStatus(
                    AudioUnitSetProperty(
                        audioUnit,
                        kAudioOutputUnitProperty_EnableIO,
                        kAudioUnitScope_Input,
                        Self.inputBus,
                        &enableInput,
                        UInt32(MemoryLayout<UInt32>.size)
                    ),
                    description: "Failed to enable VoiceProcessingIO input"
                )
                try Self.checkStatus(
                    AudioUnitSetProperty(
                        audioUnit,
                        kAudioOutputUnitProperty_EnableIO,
                        kAudioUnitScope_Output,
                        Self.outputBus,
                        &enableOutput,
                        UInt32(MemoryLayout<UInt32>.size)
                    ),
                    description: "Failed to enable VoiceProcessingIO output"
                )
                try Self.checkStatus(
                    AudioUnitSetProperty(
                        audioUnit,
                        kAudioUnitProperty_StreamFormat,
                        kAudioUnitScope_Output,
                        Self.inputBus,
                        &inputFormat,
                        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                    ),
                    description: "Failed to configure VoiceProcessingIO input stream format"
                )
                try Self.checkStatus(
                    AudioUnitSetProperty(
                        audioUnit,
                        kAudioOutputUnitProperty_SetInputCallback,
                        kAudioUnitScope_Global,
                        Self.inputBus,
                        &inputCallback,
                        UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                    ),
                    description: "Failed to install VoiceProcessingIO input callback"
                )
                try Self.checkStatus(
                    AudioUnitSetProperty(
                        audioUnit,
                        kAudioUnitProperty_StreamFormat,
                        kAudioUnitScope_Input,
                        Self.outputBus,
                        &outputFormat,
                        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                    ),
                    description: "Failed to configure VoiceProcessingIO output stream format"
                )
                try Self.checkStatus(
                    AudioUnitSetProperty(
                        audioUnit,
                        kAudioUnitProperty_SetRenderCallback,
                        kAudioUnitScope_Input,
                        Self.outputBus,
                        &outputCallback,
                        UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                    ),
                    description: "Failed to install VoiceProcessingIO output callback"
                )
                try Self.checkStatus(
                    AudioUnitInitialize(audioUnit),
                    description: "Failed to initialize VoiceProcessingIO"
                )
                try Self.checkStatus(
                    AudioOutputUnitStart(audioUnit),
                    description: "Failed to start VoiceProcessingIO"
                )
                self.audioUnit = audioUnit
            } catch {
                AudioComponentInstanceDispose(audioUnit)
                throw error
            }
        }

        func stop() {
            if let audioUnit {
                AudioOutputUnitStop(audioUnit)
                AudioUnitUninitialize(audioUnit)
                AudioComponentInstanceDispose(audioUnit)
                self.audioUnit = nil
            }

            scratchBuffer?.deallocate()
            scratchBuffer = nil
            scratchFrameCapacity = 0
            outputScratchBuffer?.deallocate()
            outputScratchBuffer = nil
            outputScratchFrameCapacity = 0
        }

        private func handleInput(
            ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
            timeStamp: UnsafePointer<AudioTimeStamp>,
            busNumber: UInt32,
            frameCount: UInt32
        ) -> OSStatus {
            guard let audioUnit else { return noErr }

            ensureScratchCapacity(frameCount)
            guard let scratchBuffer else { return noErr }

            let byteCount = frameCount * UInt32(MemoryLayout<Float>.size)
            let audioBuffer = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: byteCount,
                mData: UnsafeMutableRawPointer(scratchBuffer)
            )
            var audioBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)

            let status = AudioUnitRender(
                audioUnit,
                ioActionFlags,
                timeStamp,
                busNumber,
                frameCount,
                &audioBufferList
            )
            guard status == noErr else {
                errorHandler("VoiceProcessingIO input render failed: \(status)")
                return status
            }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: frameCount) else {
                errorHandler("Failed to allocate PCM buffer for VoiceProcessingIO input callback")
                return noErr
            }
            buffer.frameLength = frameCount
            guard let channelData = buffer.floatChannelData?.pointee else {
                errorHandler("VoiceProcessingIO PCM buffer had no float channel data")
                return noErr
            }

            memcpy(channelData, scratchBuffer, Int(byteCount))
            bufferHandler(buffer)
            return noErr
        }

        private func handleOutput(
            ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
            timeStamp: UnsafePointer<AudioTimeStamp>,
            busNumber: UInt32,
            frameCount: UInt32,
            ioData: UnsafeMutablePointer<AudioBufferList>?
        ) -> OSStatus {
            guard let ioData else {
                outputHandler()
                return noErr
            }
            let bufferList = UnsafeMutableAudioBufferListPointer(ioData)
            guard !bufferList.isEmpty else {
                outputHandler()
                return noErr
            }

            ensureOutputScratchCapacity(frameCount)
            guard let outputScratchBuffer else {
                outputHandler()
                return noErr
            }

            let outputFrameCount = Int(frameCount)
            playbackRenderer(outputScratchBuffer, outputFrameCount)

            for audioBuffer in bufferList {
                guard let data = audioBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                copyRenderedOutput(
                    outputScratchBuffer,
                    frameCount: outputFrameCount,
                    into: data,
                    channelCount: Int(max(audioBuffer.mNumberChannels, 1))
                )
            }

            outputHandler()
            return noErr
        }

        private func ensureScratchCapacity(_ frameCount: UInt32) {
            guard frameCount > scratchFrameCapacity else { return }
            scratchBuffer?.deallocate()
            scratchBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(frameCount))
            scratchFrameCapacity = frameCount
        }

        private func ensureOutputScratchCapacity(_ frameCount: UInt32) {
            guard frameCount > outputScratchFrameCapacity else { return }
            outputScratchBuffer?.deallocate()
            outputScratchBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(frameCount))
            outputScratchFrameCapacity = frameCount
        }

        private func copyRenderedOutput(
            _ source: UnsafeMutablePointer<Float>,
            frameCount: Int,
            into destination: UnsafeMutablePointer<Float>,
            channelCount: Int
        ) {
            guard frameCount > 0, channelCount > 0 else { return }

            if channelCount == 1 {
                memcpy(destination, source, frameCount * MemoryLayout<Float>.size)
                return
            }

            var outputIndex = 0
            for frameIndex in 0..<frameCount {
                let sample = source[frameIndex]
                for _ in 0..<channelCount {
                    destination[outputIndex] = sample
                    outputIndex += 1
                }
            }
        }

        private func fillSilence(_ buffer: UnsafeMutablePointer<Float>, sampleCount: Int) {
            guard sampleCount > 0 else { return }
            memset(buffer, 0, sampleCount * MemoryLayout<Float>.size)
        }

        private static func checkStatus(_ status: OSStatus, description: String) throws {
            guard status == noErr else {
                let error = NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(status),
                    userInfo: [NSLocalizedDescriptionKey: description]
                )
                throw SensorProviderError.audioEngineStartFailed(error)
            }
        }
    }

    private struct AudioFrame: Sendable {
        let timestamp: Date
        let duration: TimeInterval
        let rms: Double
        let peak: Double
        let respiratoryProxy: Double
        let lowBandRatio: Double
        let spectralCentroidHz: Double
        let tonalityScore: Double
        let zeroCrossingRate: Double
        let snoreLikeScore: Double
    }

    private struct BreathingEstimate: Sendable {
        let present: Bool
        let confidence: Double
        let periodicityScore: Double
        let rateEstimate: Double?
        let intervalCV: Double?
    }

    private struct SnoreEstimate: Sendable {
        let candidateCount: Int
        let seconds: Double
        let confidenceMax: Double
        let lowBandRatio: Double
    }

    private struct RouteState: Sendable {
        let description: String
        let hasInputRoute: Bool
    }

    private struct RuntimeState: Sendable {
        var sessionId: UUID?
        var wantsCapture = false
        var isSessionActive = false
        var engineIsRunning = false
        var tapInstalled = false
        var captureGraphKind = AudioCaptureBackendKind.voiceProcessingIOFullDuplex.rawValue
        var captureBackendKind = AudioCaptureBackendKind.voiceProcessingIOFullDuplex.rawValue
        var sessionStrategy = AudioSessionStrategyKind.voiceChatFullDuplex.rawValue
        var keepAliveOutputEnabled = false
        var hasInputRoute = false
        var frameFlowIsStalled = false
        var capturedSampleCount = 0
        var outputRenderCount = 0
        var framesSinceLastWindow = 0
        var lastWindowFrameCount = 0
        var consecutiveEmptyWindows = 0
        var restartCount = 0
        var interruptionCount = 0
        var routeChangeCount = 0
        var mediaServicesResetCount = 0
        var configurationChangeCount = 0
        var rawCaptureSegmentCount = 0
        var routeLossWhileSessionActiveCount = 0
        var frameStallCount = 0
        var aggregatedIOPreferenceEnabled = false
        var echoCancelledInputAvailable = false
        var echoCancelledInputEnabled = false
        var bundledPlaybackAvailable = false
        var bundledPlaybackEnabled = false
        var bundledPlaybackAssetName: String?
        var bundledPlaybackError: String?
        var lastObservedFrameGapSeconds = 0.0
        var lastFrameAt: Date?
        var lastNonEmptyWindowAt: Date?
        var lastRestartAt: Date?
        var lastInterruptionAt: Date?
        var lastRouteChangeAt: Date?
        var lastMediaServicesResetAt: Date?
        var lastConfigurationChangeAt: Date?
        var lastActivationAttemptAt: Date?
        var lastSuccessfulActivationAt: Date?
        var lastRouteLossAt: Date?
        var lastFrameStallAt: Date?
        var lastFrameRecoveryAt: Date?
        var lastOutputRenderAt: Date?
        var lastRestartReason: String?
        var lastActivationReason: String?
        var lastActivationContext: String?
        var lastInterruptionReason: String?
        var lastInterruptionWasSuspended = false
        var lastRouteChangeReason: String?
        var lastRouteLossReason: String?
        var lastFrameStallReason: String?
        var lastKnownRoute: String?
        var activeRawCaptureFileName: String?
        var lastActivationErrorDomain: String?
        var lastActivationErrorCode: Int?
        var repairSuppressedReason: String?
        var lastRepairDecision: String?
        var aggregatedIOPreferenceError: String?
        var rawCaptureError: String?
        var lastError: String?
    }

    private struct RawCaptureStorage {
        var currentFile: AVAudioFile?
        var currentURL: URL?
        var urls: [URL] = []
    }

    let providerId = "audio.live"

    private var captureBackend: VoiceProcessingCaptureBackend?
    private var captureWatchdogTimer: DispatchSourceTimer?
    private let sessionStrategy: AudioSessionStrategyKind
    private let bundledPlaybackController: BundledPlaybackController
    private let samples: ThreadSafeArray<AudioFrame>
    private let runtimeState: ThreadSafeBox<RuntimeState>
    private let rawCaptureStorage: ThreadSafeBox<RawCaptureStorage>
    private let managementQueue = DispatchQueue(label: "com.rickluo.SleepDetectionPOC.audio.live")
    private let observerTokens: ThreadSafeBox<[NSObjectProtocol]>
    private static let watchdogInterval: TimeInterval = 5
    private static let frameStallThreshold: TimeInterval = 8
    private static let initialFrameGracePeriod: TimeInterval = 3
    private static let analysisFrequencies: [Double] = [150, 250, 400, 800, 1_200, 2_400]

    init(
        maxSamples: Int = 10000,
        sessionStrategy: AudioSessionStrategyKind = .voiceChatFullDuplex
    ) {
        self.sessionStrategy = sessionStrategy
        self.bundledPlaybackController = BundledPlaybackController(
            resourceName: "0001ZM20251208_A",
            fileExtension: "mp3"
        )
        self.samples = ThreadSafeArray(maxSize: maxSamples)
        self.runtimeState = ThreadSafeBox(RuntimeState())
        self.rawCaptureStorage = ThreadSafeBox(RawCaptureStorage())
        self.observerTokens = ThreadSafeBox([])
        registerForNotifications()
    }

    deinit {
        observerTokens.read { tokens in
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
        captureWatchdogTimer?.cancel()
    }

    func start(session: Session) throws {
        samples.removeAll()

        guard PermissionHelper.microphoneGranted() else {
            throw SensorProviderError.microphonePermissionDenied
        }

        do {
            try managementQueue.sync {
                guard !runtimeState.read({ $0.wantsCapture }) else { return }
                cleanupRawCaptureFiles()
                bundledPlaybackController.stop()
                let routeState = currentRouteState()
                runtimeState.write { state in
                    state = RuntimeState()
                    state.sessionId = session.sessionId
                    state.wantsCapture = true
                    state.captureGraphKind = AudioCaptureBackendKind.voiceProcessingIOFullDuplex.rawValue
                    state.captureBackendKind = AudioCaptureBackendKind.voiceProcessingIOFullDuplex.rawValue
                    state.sessionStrategy = sessionStrategy.rawValue
                    state.keepAliveOutputEnabled = false
                    state.lastKnownRoute = routeState.description
                    state.hasInputRoute = routeState.hasInputRoute
                }
                syncBundledPlaybackRuntimeLocked()

                do {
                    try activateAudioSession(reason: "initialStart")
                    try startCaptureBackendLocked(reason: "initialStart", rebuildBackend: true)
                    startCaptureWatchdogLocked()
                } catch let error as SensorProviderError {
                    runtimeState.write {
                        $0.wantsCapture = false
                        $0.lastError = error.localizedDescription
                    }
                    throw error
                } catch {
                    runtimeState.write {
                        $0.wantsCapture = false
                        $0.lastError = error.localizedDescription
                    }
                    throw error
                }
            }
        } catch let error as SensorProviderError {
            throw error
        } catch {
            throw SensorProviderError.audioEngineStartFailed(error)
        }
    }

    func stop() {
        managementQueue.sync {
            bundledPlaybackController.stop()
            let routeState = currentRouteState()
            runtimeState.write { state in
                state.wantsCapture = false
                state.sessionId = nil
                state.consecutiveEmptyWindows = 0
                state.framesSinceLastWindow = 0
                state.lastWindowFrameCount = 0
                state.activeRawCaptureFileName = nil
                state.rawCaptureSegmentCount = 0
                state.rawCaptureError = nil
                state.lastKnownRoute = routeState.description
                state.hasInputRoute = routeState.hasInputRoute
                state.frameFlowIsStalled = false
                state.lastObservedFrameGapSeconds = 0
                state.repairSuppressedReason = nil
                state.lastRepairDecision = nil
            }
            syncBundledPlaybackRuntimeLocked()
            stopCaptureWatchdogLocked()
            stopCaptureAndDeactivateSession(clearSamples: true)
            cleanupRawCaptureFiles()
        }
    }

    func currentWindow() -> SensorWindowSnapshot? {
        SensorWindowSnapshot(
            motion: nil,
            audio: aggregate(shouldDrain: false).features,
            interaction: nil,
            watch: nil
        )
    }

    func consumeWindow(windowDuration: TimeInterval) -> AudioFeatures? {
        let (features, frameCount) = aggregate(shouldDrain: true, fallbackDuration: windowDuration)
        let now = Date()
        runtimeState.write { state in
            state.lastWindowFrameCount = frameCount
            state.framesSinceLastWindow = 0
            if features == nil {
                state.consecutiveEmptyWindows += 1
            } else {
                state.consecutiveEmptyWindows = 0
                state.lastNonEmptyWindowAt = now
            }
        }
        return features
    }

    func runtimeSnapshot() -> AudioRuntimeSnapshot {
        let state = runtimeState.value
        return AudioRuntimeSnapshot(
            wantsCapture: state.wantsCapture,
            isSessionActive: state.isSessionActive,
            engineIsRunning: state.engineIsRunning,
            tapInstalled: state.tapInstalled,
            captureGraphKind: state.captureGraphKind,
            captureBackendKind: state.captureBackendKind,
            sessionStrategy: state.sessionStrategy,
            keepAliveOutputEnabled: state.keepAliveOutputEnabled,
            hasInputRoute: state.hasInputRoute,
            frameFlowIsStalled: state.frameFlowIsStalled,
            bufferedSampleCount: samples.count,
            capturedSampleCount: state.capturedSampleCount,
            outputRenderCount: state.outputRenderCount,
            framesSinceLastWindow: state.framesSinceLastWindow,
            lastWindowFrameCount: state.lastWindowFrameCount,
            consecutiveEmptyWindows: state.consecutiveEmptyWindows,
            restartCount: state.restartCount,
            interruptionCount: state.interruptionCount,
            routeChangeCount: state.routeChangeCount,
            mediaServicesResetCount: state.mediaServicesResetCount,
            configurationChangeCount: state.configurationChangeCount,
            rawCaptureSegmentCount: state.rawCaptureSegmentCount,
            routeLossWhileSessionActiveCount: state.routeLossWhileSessionActiveCount,
            frameStallCount: state.frameStallCount,
            aggregatedIOPreferenceEnabled: state.aggregatedIOPreferenceEnabled,
            lastObservedFrameGapSeconds: state.lastObservedFrameGapSeconds,
            lastFrameAt: state.lastFrameAt,
            lastNonEmptyWindowAt: state.lastNonEmptyWindowAt,
            lastRestartAt: state.lastRestartAt,
            lastInterruptionAt: state.lastInterruptionAt,
            lastRouteChangeAt: state.lastRouteChangeAt,
            lastMediaServicesResetAt: state.lastMediaServicesResetAt,
            lastConfigurationChangeAt: state.lastConfigurationChangeAt,
            lastActivationAttemptAt: state.lastActivationAttemptAt,
            lastSuccessfulActivationAt: state.lastSuccessfulActivationAt,
            lastRouteLossAt: state.lastRouteLossAt,
            lastFrameStallAt: state.lastFrameStallAt,
            lastFrameRecoveryAt: state.lastFrameRecoveryAt,
            lastOutputRenderAt: state.lastOutputRenderAt,
            lastRestartReason: state.lastRestartReason,
            lastActivationReason: state.lastActivationReason,
            lastActivationContext: state.lastActivationContext,
            lastInterruptionReason: state.lastInterruptionReason,
            lastInterruptionWasSuspended: state.lastInterruptionWasSuspended,
            lastRouteChangeReason: state.lastRouteChangeReason,
            lastRouteLossReason: state.lastRouteLossReason,
            lastFrameStallReason: state.lastFrameStallReason,
            lastKnownRoute: state.lastKnownRoute,
            activeRawCaptureFileName: state.activeRawCaptureFileName,
            lastActivationErrorDomain: state.lastActivationErrorDomain,
            lastActivationErrorCode: state.lastActivationErrorCode,
            repairSuppressedReason: state.repairSuppressedReason,
            lastRepairDecision: state.lastRepairDecision,
            echoCancelledInputAvailable: state.echoCancelledInputAvailable,
            echoCancelledInputEnabled: state.echoCancelledInputEnabled,
            bundledPlaybackAvailable: state.bundledPlaybackAvailable,
            bundledPlaybackEnabled: state.bundledPlaybackEnabled,
            bundledPlaybackAssetName: state.bundledPlaybackAssetName,
            bundledPlaybackError: state.bundledPlaybackError,
            aggregatedIOPreferenceError: state.aggregatedIOPreferenceError,
            rawCaptureError: state.rawCaptureError,
            lastError: state.lastError
        )
    }

    func ensureRunning(reason: String) {
        managementQueue.async { [weak self] in
            self?.ensureCaptureRunningLocked(
                reason: reason,
                allowSessionActivation: true,
                forceRebuildBackend: false
            )
        }
    }

    func setBundledPlaybackEnabled(_ enabled: Bool) {
        managementQueue.sync {
            if enabled, runtimeState.read({ $0.wantsCapture }) {
                prepareBundledPlaybackAssetLocked(outputFormat: makeCaptureFormat())
            }
            bundledPlaybackController.setEnabled(enabled)
            syncBundledPlaybackRuntimeLocked()
        }
    }

    private func aggregate(
        shouldDrain: Bool,
        fallbackDuration: TimeInterval = 30
    ) -> (features: AudioFeatures?, frameCount: Int) {
        let currentFrames: [AudioFrame]
        if shouldDrain {
            currentFrames = samples.drain()
        } else {
            currentFrames = samples.allElements()
        }

        guard !currentFrames.isEmpty else {
            return (nil, 0)
        }

        let orderedFrames = currentFrames.sorted { $0.timestamp < $1.timestamp }
        let rmsValues = currentFrames.map(\.rms)
        let peaks = currentFrames.map(\.peak)
        let meanRMS = rmsValues.reduce(0, +) / Double(rmsValues.count)
        let variance = rmsValues.reduce(0) { partialResult, value in
            partialResult + pow(value - meanRMS, 2)
        } / Double(rmsValues.count)
        let avgPeak = peaks.reduce(0, +) / Double(peaks.count)
        let spikeThreshold = max(meanRMS * 2.4, 0.05)
        let frictionEvents = peaks.filter { $0 >= spikeThreshold }.count
        let isSilent = meanRMS < 0.015 && avgPeak < 0.05
        let frameInterval = Self.estimateFrameInterval(from: orderedFrames, fallbackDuration: fallbackDuration)
        let meanLowBandRatio = orderedFrames.map(\.lowBandRatio).reduce(0, +) / Double(orderedFrames.count)
        let meanTonality = orderedFrames.map(\.tonalityScore).reduce(0, +) / Double(orderedFrames.count)
        let meanCentroid = orderedFrames.map(\.spectralCentroidHz).reduce(0, +) / Double(orderedFrames.count)
        let highCentroidRatio = Double(
            orderedFrames.filter { $0.spectralCentroidHz > 1_600 || $0.zeroCrossingRate > 0.18 }.count
        ) / Double(orderedFrames.count)
        let varianceNorm = Self.clamp(variance / 0.0012)
        let frictionRate = Self.clamp(Double(frictionEvents) * frameInterval / max(1, fallbackDuration / 4))
        let disturbanceScore = Self.clamp(varianceNorm * 0.45 + frictionRate * 0.35 + highCentroidRatio * 0.20)
        let tonalLeakage = Self.clamp((meanTonality - 0.58) / 0.30)
        let centroidLeakage = Self.clamp((meanCentroid - 900) / 1_200)
        let playbackLeakageScore = Self.clamp(tonalLeakage * (0.55 + 0.45 * centroidLeakage))
        let breathingEstimate = Self.estimateBreathing(
            from: orderedFrames,
            fallbackDuration: fallbackDuration,
            isSilent: isSilent,
            disturbanceScore: disturbanceScore,
            playbackLeakageScore: playbackLeakageScore,
            meanLowBandRatio: meanLowBandRatio
        )
        let snoreEstimate = Self.estimateSnore(
            from: orderedFrames,
            fallbackDuration: fallbackDuration,
            meanRMS: meanRMS,
            playbackLeakageScore: playbackLeakageScore
        )

        return (
            AudioFeatures(
                envNoiseLevel: meanRMS,
                envNoiseVariance: variance,
                breathingRateEstimate: breathingEstimate.rateEstimate,
                frictionEventCount: frictionEvents,
                isSilent: isSilent,
                breathingPresent: breathingEstimate.present,
                breathingConfidence: breathingEstimate.confidence,
                breathingPeriodicityScore: breathingEstimate.periodicityScore,
                breathingIntervalCV: breathingEstimate.intervalCV,
                disturbanceScore: disturbanceScore,
                playbackLeakageScore: playbackLeakageScore,
                snoreCandidateCount: snoreEstimate.candidateCount,
                snoreSeconds: snoreEstimate.seconds,
                snoreConfidenceMax: snoreEstimate.confidenceMax,
                snoreLowBandRatio: snoreEstimate.lowBandRatio
            ),
            currentFrames.count
        )
    }

    private static func extractFrame(from buffer: AVAudioPCMBuffer) -> AudioFrame? {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }
        guard let channelData = buffer.floatChannelData?.pointee else { return nil }
        let sampleRate = buffer.format.sampleRate
        var sumSquares = 0.0
        var peak = 0.0
        var zeroCrossings = 0

        for index in 0..<frameLength {
            let value = Double(channelData[index])
            let absolute = abs(value)
            sumSquares += value * value
            peak = max(peak, absolute)
            if index > 0 {
                let previous = channelData[index - 1]
                if (previous >= 0 && channelData[index] < 0) || (previous < 0 && channelData[index] >= 0) {
                    zeroCrossings += 1
                }
            }
        }

        let rms = sqrt(sumSquares / Double(frameLength))
        let bandPowers = Self.analysisFrequencies.map {
            Self.goertzelPower(
                samples: channelData,
                count: frameLength,
                sampleRate: sampleRate,
                targetFrequency: $0
            )
        }
        let lowBandPower = bandPowers[0] + bandPowers[1] + bandPowers[2]
        let midBandPower = bandPowers[3] + bandPowers[4]
        let highBandPower = bandPowers[5]
        let bandTotal = max(lowBandPower + midBandPower + highBandPower, .leastNonzeroMagnitude)
        let lowBandRatio = lowBandPower / bandTotal
        let spectralCentroid = zip(Self.analysisFrequencies, bandPowers).reduce(0.0) { partial, pair in
            partial + pair.0 * pair.1
        } / bandTotal
        let tonalityScore = (bandPowers.max() ?? 0) / bandTotal
        let zeroCrossingRate = Double(zeroCrossings) / Double(max(frameLength - 1, 1))
        let respiratoryProxy = rms * max(lowBandRatio, 0.05)
        let energySupport = Self.clamp((rms - 0.008) / 0.04)
        let lowBandSupport = Self.clamp((lowBandRatio - 0.45) / 0.35)
        let centroidSupport = 1 - Self.clamp((spectralCentroid - 1_400) / 1_600)
        let zeroCrossSupport = 1 - Self.clamp((zeroCrossingRate - 0.18) / 0.22)
        let broadbandPenalty = Self.clamp((tonalityScore - 0.82) / 0.18)
        let snoreLikeScore = Self.clamp(
            energySupport * 0.30 +
            lowBandSupport * 0.25 +
            centroidSupport * 0.20 +
            zeroCrossSupport * 0.15 +
            (1 - broadbandPenalty) * 0.10
        )

        return AudioFrame(
            timestamp: Date(),
            duration: Double(frameLength) / sampleRate,
            rms: rms,
            peak: peak,
            respiratoryProxy: respiratoryProxy,
            lowBandRatio: lowBandRatio,
            spectralCentroidHz: spectralCentroid,
            tonalityScore: tonalityScore,
            zeroCrossingRate: zeroCrossingRate,
            snoreLikeScore: snoreLikeScore
        )
    }

    private func ingestCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        guard var frame = Self.extractFrame(from: buffer) else { return }
        let now = Date()
        frame = AudioFrame(
            timestamp: now,
            duration: frame.duration,
            rms: frame.rms,
            peak: frame.peak,
            respiratoryProxy: frame.respiratoryProxy,
            lowBandRatio: frame.lowBandRatio,
            spectralCentroidHz: frame.spectralCentroidHz,
            tonalityScore: frame.tonalityScore,
            zeroCrossingRate: frame.zeroCrossingRate,
            snoreLikeScore: frame.snoreLikeScore
        )
        samples.append(frame)
        runtimeState.write { state in
            state.lastFrameAt = now
            state.capturedSampleCount += 1
            state.framesSinceLastWindow += 1
            state.lastObservedFrameGapSeconds = 0
            if state.frameFlowIsStalled {
                state.frameFlowIsStalled = false
                state.lastFrameRecoveryAt = now
                state.lastError = nil
            }
        }
        writeBufferToRawCapture(buffer)
    }

    private static func goertzelPower(
        samples: UnsafePointer<Float>,
        count: Int,
        sampleRate: Double,
        targetFrequency: Double
    ) -> Double {
        guard count > 0, sampleRate > 0, targetFrequency > 0 else { return 0 }

        let k = max(1, Int(0.5 + (Double(count) * targetFrequency / sampleRate)))
        let omega = 2 * Double.pi * Double(k) / Double(count)
        let coefficient = 2 * cos(omega)
        var q0 = 0.0
        var q1 = 0.0
        var q2 = 0.0

        for index in 0..<count {
            q0 = coefficient * q1 - q2 + Double(samples[index])
            q2 = q1
            q1 = q0
        }

        return max(0, q1 * q1 + q2 * q2 - coefficient * q1 * q2)
    }

    private static func estimateFrameInterval(
        from frames: [AudioFrame],
        fallbackDuration: TimeInterval
    ) -> TimeInterval {
        let diffs = zip(frames.dropFirst(), frames).compactMap { lhs, rhs -> TimeInterval? in
            let diff = lhs.timestamp.timeIntervalSince(rhs.timestamp)
            guard diff > 0.001, diff < 1 else { return nil }
            return diff
        }
        guard !diffs.isEmpty else {
            return max(0.01, min(0.25, fallbackDuration / Double(max(frames.count, 1))))
        }
        let sorted = diffs.sorted()
        return sorted[sorted.count / 2]
    }

    private static func movingAverage(_ values: [Double], windowSize: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        let windowSize = max(1, min(windowSize, values.count))
        if windowSize == 1 { return values }

        var result: [Double] = []
        result.reserveCapacity(values.count)
        var runningSum = 0.0

        for index in values.indices {
            runningSum += values[index]
            if index >= windowSize {
                runningSum -= values[index - windowSize]
            }
            let divisor = min(index + 1, windowSize)
            result.append(runningSum / Double(divisor))
        }

        return result
    }

    private static func normalizedAutocorrelation(_ values: [Double], lag: Int) -> Double {
        guard lag > 0, lag < values.count else { return 0 }

        var numerator = 0.0
        var energyLeft = 0.0
        var energyRight = 0.0

        for index in 0..<(values.count - lag) {
            let lhs = values[index]
            let rhs = values[index + lag]
            numerator += lhs * rhs
            energyLeft += lhs * lhs
            energyRight += rhs * rhs
        }

        let denominator = sqrt(max(energyLeft * energyRight, .leastNonzeroMagnitude))
        guard denominator > 0 else { return 0 }
        return numerator / denominator
    }

    private static func detectIntervals(
        in values: [Double],
        sampleInterval: TimeInterval
    ) -> [Double] {
        guard values.count >= 3 else { return [] }

        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { partialResult, value in
            partialResult + pow(value - mean, 2)
        } / Double(values.count)
        let threshold = mean + sqrt(variance) * 0.25
        let minimumGap = max(1, Int(1.5 / sampleInterval))
        var peakIndices: [Int] = []
        var lastPeakIndex = -minimumGap

        for index in 1..<(values.count - 1) {
            guard
                values[index] > threshold,
                values[index] >= values[index - 1],
                values[index] >= values[index + 1],
                index - lastPeakIndex >= minimumGap
            else {
                continue
            }
            peakIndices.append(index)
            lastPeakIndex = index
        }

        return zip(peakIndices.dropFirst(), peakIndices).compactMap { lhs, rhs in
            let seconds = Double(lhs - rhs) * sampleInterval
            guard seconds >= 2.5, seconds <= 10 else { return nil }
            return seconds
        }
    }

    private static func estimateBreathing(
        from frames: [AudioFrame],
        fallbackDuration: TimeInterval,
        isSilent: Bool,
        disturbanceScore: Double,
        playbackLeakageScore: Double,
        meanLowBandRatio: Double
    ) -> BreathingEstimate {
        guard fallbackDuration >= 20, frames.count >= 20, !isSilent else {
            return BreathingEstimate(
                present: false,
                confidence: 0,
                periodicityScore: 0,
                rateEstimate: nil,
                intervalCV: nil
            )
        }

        let frameInterval = estimateFrameInterval(from: frames, fallbackDuration: fallbackDuration)
        let smoothingWindow = max(1, Int(0.25 / frameInterval))
        let respiratorySeries = movingAverage(frames.map(\.respiratoryProxy), windowSize: smoothingWindow)
        let mean = respiratorySeries.reduce(0, +) / Double(respiratorySeries.count)
        let centered = respiratorySeries.map { $0 - mean }
        let energy = centered.reduce(0) { $0 + $1 * $1 }
        guard energy > .leastNonzeroMagnitude else {
            return BreathingEstimate(
                present: false,
                confidence: 0,
                periodicityScore: 0,
                rateEstimate: nil,
                intervalCV: nil
            )
        }

        let minimumLag = max(1, Int(2.5 / frameInterval))
        let maximumLag = min(centered.count - 1, max(minimumLag + 1, Int(10 / frameInterval)))

        var bestLag = minimumLag
        var bestCorrelation = 0.0
        for lag in minimumLag...maximumLag {
            let correlation = normalizedAutocorrelation(centered, lag: lag)
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }

        let estimatedRate = 60 / (Double(bestLag) * frameInterval)
        let intervals = detectIntervals(in: respiratorySeries, sampleInterval: frameInterval)
        let intervalCV: Double?
        if intervals.count >= 2 {
            let intervalMean = intervals.reduce(0, +) / Double(intervals.count)
            let intervalVariance = intervals.reduce(0) { partialResult, value in
                partialResult + pow(value - intervalMean, 2)
            } / Double(intervals.count)
            intervalCV = intervalMean > 0 ? sqrt(intervalVariance) / intervalMean : nil
        } else {
            intervalCV = nil
        }

        let stability = intervalCV.map { clamp(1 - ($0 / 0.6)) } ?? 0.25
        let lowBandSupport = clamp((meanLowBandRatio - 0.30) / 0.40)
        var confidence = clamp(bestCorrelation * 0.55 + stability * 0.25 + lowBandSupport * 0.20)
        confidence *= (1 - disturbanceScore * 0.55)
        confidence *= (1 - playbackLeakageScore * 0.75)
        let present =
            confidence >= 0.50 &&
            bestCorrelation >= 0.36 &&
            (intervalCV ?? 0.35) <= 0.5 &&
            estimatedRate >= 6 && estimatedRate <= 24

        return BreathingEstimate(
            present: present,
            confidence: confidence,
            periodicityScore: clamp(bestCorrelation),
            rateEstimate: present ? estimatedRate : nil,
            intervalCV: intervalCV
        )
    }

    private static func estimateSnore(
        from frames: [AudioFrame],
        fallbackDuration: TimeInterval,
        meanRMS: Double,
        playbackLeakageScore: Double
    ) -> SnoreEstimate {
        guard fallbackDuration >= 10, frames.count >= 10 else {
            return SnoreEstimate(candidateCount: 0, seconds: 0, confidenceMax: 0, lowBandRatio: 0)
        }

        let energyFloor = max(meanRMS * 1.20, 0.01)
        var startIndex: Int?
        var lastQualifiedIndex: Int?
        var confidenceValues: [Double] = []
        var totalSeconds = 0.0
        var maxConfidence = 0.0
        var lowBandAccumulator = 0.0

        func finalizeEvent(endIndex: Int) {
            guard let startIndex else { return }
            let eventFrames = Array(frames[startIndex...endIndex])
            let duration = eventFrames.reduce(0) { $0 + $1.duration }
            guard duration >= 0.25, duration <= 2.0 else { return }

            let meanScore = eventFrames.map(\.snoreLikeScore).reduce(0, +) / Double(eventFrames.count)
            let meanLowBandRatio = eventFrames.map(\.lowBandRatio).reduce(0, +) / Double(eventFrames.count)
            let meanCentroid = eventFrames.map(\.spectralCentroidHz).reduce(0, +) / Double(eventFrames.count)
            let confidence = clamp(meanScore * (1 - playbackLeakageScore * 0.60))

            guard meanLowBandRatio >= 0.42, meanCentroid <= 1_500, confidence >= 0.45 else { return }
            confidenceValues.append(confidence)
            totalSeconds += duration
            maxConfidence = max(maxConfidence, confidence)
            lowBandAccumulator += meanLowBandRatio
        }

        for index in frames.indices {
            let frame = frames[index]
            let qualifies =
                frame.snoreLikeScore >= 0.58 &&
                frame.rms >= energyFloor &&
                frame.tonalityScore <= 0.92

            if qualifies {
                if startIndex == nil {
                    startIndex = index
                }
                lastQualifiedIndex = index
                continue
            }

            if let lastDetectedIndex = lastQualifiedIndex, startIndex != nil, index - lastDetectedIndex > 1 {
                finalizeEvent(endIndex: lastDetectedIndex)
                startIndex = nil
                lastQualifiedIndex = nil
            } else if startIndex == nil {
                continue
            }
        }

        if let lastQualifiedIndex {
            finalizeEvent(endIndex: lastQualifiedIndex)
        }

        guard !confidenceValues.isEmpty else {
            return SnoreEstimate(candidateCount: 0, seconds: 0, confidenceMax: 0, lowBandRatio: 0)
        }

        return SnoreEstimate(
            candidateCount: confidenceValues.count,
            seconds: totalSeconds,
            confidenceMax: maxConfidence,
            lowBandRatio: lowBandAccumulator / Double(confidenceValues.count)
        )
    }

    private static func clamp(_ value: Double, lower: Double = 0, upper: Double = 1) -> Double {
        min(max(value, lower), upper)
    }

    private func prepareBundledPlaybackAssetLocked(outputFormat: AVAudioFormat) {
        bundledPlaybackController.prepareIfNeeded(outputFormat: outputFormat)
        syncBundledPlaybackRuntimeLocked()
    }

    private func syncBundledPlaybackRuntimeLocked() {
        let snapshot = bundledPlaybackController.snapshot()
        runtimeState.write { state in
            state.bundledPlaybackAvailable = snapshot.available
            state.bundledPlaybackEnabled = snapshot.enabled
            state.bundledPlaybackAssetName = snapshot.assetName
            state.bundledPlaybackError = snapshot.error
        }
    }

    private func recordOutputRender() {
        let now = Date()
        runtimeState.write { state in
            state.keepAliveOutputEnabled = true
            state.outputRenderCount += 1
            state.lastOutputRenderAt = now
        }
    }

    private func registerForNotifications() {
        let center = NotificationCenter.default
        let audioSession = AVAudioSession.sharedInstance()

        let tokens = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: audioSession,
                queue: nil
            ) { [weak self] notification in
                self?.handleAudioSessionInterruption(notification)
            },
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: audioSession,
                queue: nil
            ) { [weak self] notification in
                self?.handleAudioRouteChange(notification)
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: audioSession,
                queue: nil
            ) { [weak self] _ in
                self?.handleMediaServicesReset()
            }
        ]

        observerTokens.write { $0 = tokens }
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }

        let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
        let reasonLabel: String?
        if
            let rawReason = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt,
            let reason = AVAudioSession.InterruptionReason(rawValue: rawReason)
        {
            reasonLabel = Self.interruptionReasonLabel(for: reason)
        } else {
            reasonLabel = nil
        }
        let wasSuspended = reasonLabel == "appWasSuspended"
        let now = Date()

        managementQueue.async { [weak self] in
            guard let self else { return }

            switch type {
            case .began:
                let routeState = self.currentRouteState()
                self.stopCaptureBackendLocked(reason: "interruptionBegan")
                self.runtimeState.write { state in
                    state.interruptionCount += 1
                    state.lastInterruptionAt = now
                    state.isSessionActive = false
                    state.lastInterruptionReason = reasonLabel
                    state.lastInterruptionWasSuspended = wasSuspended
                    state.lastKnownRoute = routeState.description
                    state.hasInputRoute = routeState.hasInputRoute
                    state.lastRepairDecision = "deferredInterruptionBegan"
                    state.repairSuppressedReason = nil
                }
            case .ended:
                let routeState = self.currentRouteState()
                self.runtimeState.write { state in
                    state.lastInterruptionAt = now
                    state.lastInterruptionReason = reasonLabel
                    state.lastInterruptionWasSuspended = wasSuspended
                    state.lastKnownRoute = routeState.description
                    state.hasInputRoute = routeState.hasInputRoute
                }
                guard options.contains(.shouldResume) else {
                    self.markRepairDecisionLocked("deferredInterruptionNoResume")
                    return
                }
                self.ensureCaptureRunningLocked(
                    reason: "interruptionEndedShouldResume",
                    allowSessionActivation: true,
                    forceRebuildBackend: true
                )
            @unknown default:
                break
            }
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        let reasonLabel: String
        if
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        {
            reasonLabel = Self.routeChangeReasonLabel(for: reason)
        } else {
            reasonLabel = "unknown"
        }

        let now = Date()
        managementQueue.async { [weak self] in
            guard let self else { return }
            let routeState = self.currentRouteState()
            self.runtimeState.write { state in
                state.routeChangeCount += 1
                state.lastRouteChangeAt = now
                state.lastRouteChangeReason = reasonLabel
                state.lastKnownRoute = routeState.description
                state.hasInputRoute = routeState.hasInputRoute
                if !routeState.hasInputRoute, state.wantsCapture, state.isSessionActive {
                    state.lastRouteLossAt = now
                    state.routeLossWhileSessionActiveCount += 1
                    state.lastRouteLossReason = reasonLabel
                }
            }
            self.syncEchoCancelledCapabilityLocked()
            guard routeState.hasInputRoute else {
                self.markRepairDecisionLocked("deferredNoInputRoute")
                return
            }
            self.repairCaptureBackendIfPossibleLocked(reason: "routeChange:\(reasonLabel)")
        }
    }

    private func handleMediaServicesReset() {
        let now = Date()
        managementQueue.async { [weak self] in
            guard let self else { return }
            let routeState = self.currentRouteState()
            self.stopCaptureBackendLocked(reason: "mediaServicesReset")
            self.runtimeState.write { state in
                state.mediaServicesResetCount += 1
                state.lastMediaServicesResetAt = now
                state.isSessionActive = false
                state.lastKnownRoute = routeState.description
                state.hasInputRoute = routeState.hasInputRoute
            }
            self.ensureCaptureRunningLocked(
                reason: "mediaServicesReset",
                allowSessionActivation: true,
                forceRebuildBackend: true
            )
        }
    }

    private func ensureCaptureRunningLocked(
        reason: String,
        allowSessionActivation: Bool,
        forceRebuildBackend: Bool
    ) {
        guard runtimeState.read({ $0.wantsCapture }) else { return }

        let now = Date()
        let frameFlowIsStalled = updateFrameFlowHealthLocked(now: now, reason: reason)
        let snapshot = runtimeState.value
        let recentlyAttemptedActivation = snapshot.lastActivationAttemptAt.map {
            now.timeIntervalSince($0) < 2
        } ?? false
        let needsBackendRestart = forceRebuildBackend || frameFlowIsStalled || !snapshot.engineIsRunning || !snapshot.tapInstalled

        if snapshot.isSessionActive {
            if !snapshot.hasInputRoute {
                if let suppression = repairSuppressionReason(for: snapshot, recentlyAttemptedActivation: recentlyAttemptedActivation) {
                    markRepairDecisionLocked("suppressedNoInputRoute", suppressedReason: suppression)
                } else {
                    markRepairDecisionLocked("deferredNoInputRoute")
                }
                return
            }

            guard needsBackendRestart else {
                markRepairDecisionLocked("noopHealthy")
                return
            }

            do {
                try startCaptureBackendLocked(reason: reason, rebuildBackend: true)
                markRepairDecisionLocked("restartBackend")
            } catch {
                recordNonActivationError(error)
            }
            return
        }

        guard allowSessionActivation else {
            markRepairDecisionLocked("deferredActivationDisallowed")
            return
        }

        if let suppression = repairSuppressionReason(for: snapshot, recentlyAttemptedActivation: recentlyAttemptedActivation) {
            markRepairDecisionLocked("suppressedSessionActivation", suppressedReason: suppression)
            return
        }

        do {
            try activateAudioSession(reason: reason)
            guard runtimeState.read({ $0.hasInputRoute }) else {
                markRepairDecisionLocked("deferredNoInputRoute")
                return
            }
            try startCaptureBackendLocked(reason: reason, rebuildBackend: true)
            markRepairDecisionLocked("activateSessionAndRestartBackend")
        } catch {
            if case SensorProviderError.audioSessionFailed = error {
                runtimeState.write { state in
                    state.engineIsRunning = false
                    state.tapInstalled = false
                    state.lastRepairDecision = "activationFailed"
                    state.repairSuppressedReason = nil
                }
            } else {
                recordNonActivationError(error)
            }
        }
    }

    private func repairCaptureBackendIfPossibleLocked(reason: String) {
        guard runtimeState.read({ $0.wantsCapture && $0.isSessionActive && $0.hasInputRoute }) else { return }

        let snapshot = runtimeState.value
        let frameFlowIsStalled = updateFrameFlowHealthLocked(now: Date(), reason: reason)
        guard frameFlowIsStalled || !snapshot.engineIsRunning || !snapshot.tapInstalled else {
            markRepairDecisionLocked("noopHealthy")
            return
        }

        do {
            try startCaptureBackendLocked(reason: reason, rebuildBackend: true)
            markRepairDecisionLocked("restartBackend")
        } catch {
            recordNonActivationError(error)
        }
    }

    private func activateAudioSession(reason: String) throws {
        let audioSession = AVAudioSession.sharedInstance()
        let now = Date()
        let routeStateBeforeActivation = currentRouteState()
        runtimeState.write { state in
            state.lastActivationAttemptAt = now
            state.lastActivationReason = reason
            state.lastActivationContext = Self.activationContextLabel(for: reason)
            state.lastKnownRoute = routeStateBeforeActivation.description
            state.hasInputRoute = routeStateBeforeActivation.hasInputRoute
            state.lastActivationErrorDomain = nil
            state.lastActivationErrorCode = nil
        }

        do {
            if audioSession.category != sessionStrategy.category
                || audioSession.mode != sessionStrategy.mode
                || audioSession.categoryOptions.rawValue != sessionStrategy.categoryOptions.rawValue {
                try audioSession.setCategory(
                    sessionStrategy.category,
                    mode: sessionStrategy.mode,
                    options: sessionStrategy.categoryOptions
                )
            }

            if #available(iOS 18.2, *) {
                if sessionStrategy.prefersEchoCancelledInput {
                    try audioSession.setPrefersEchoCancelledInput(true)
                }
            }

            let aggregatedIOPreferenceEnabled: Bool
            let aggregatedPreferenceError: String?
            do {
                try audioSession.setAggregatedIOPreference(.aggregated)
                aggregatedIOPreferenceEnabled = true
                aggregatedPreferenceError = nil
            } catch {
                aggregatedIOPreferenceEnabled = false
                aggregatedPreferenceError = error.localizedDescription
            }

            try audioSession.setActive(true)
            let routeStateAfterActivation = currentRouteState()
            runtimeState.write { state in
                state.isSessionActive = true
                state.lastSuccessfulActivationAt = Date()
                state.lastKnownRoute = routeStateAfterActivation.description
                state.hasInputRoute = routeStateAfterActivation.hasInputRoute
                state.lastActivationErrorDomain = nil
                state.lastActivationErrorCode = nil
                state.aggregatedIOPreferenceEnabled = aggregatedIOPreferenceEnabled
                state.aggregatedIOPreferenceError = aggregatedPreferenceError
                state.lastError = nil
            }
            syncEchoCancelledCapabilityLocked()
        } catch {
            let nsError = Self.unwrapNSError(from: error)
            let routeStateAfterFailure = currentRouteState()
            runtimeState.write { state in
                state.isSessionActive = false
                state.lastKnownRoute = routeStateAfterFailure.description
                state.hasInputRoute = routeStateAfterFailure.hasInputRoute
                state.lastActivationErrorDomain = nsError.domain
                state.lastActivationErrorCode = nsError.code
                state.lastError = error.localizedDescription
                state.repairSuppressedReason = nil
                state.lastRepairDecision = "activationFailed"
            }
            throw SensorProviderError.audioSessionFailed(error)
        }
    }

    private func startCaptureBackendLocked(reason: String, rebuildBackend: Bool) throws {
        if rebuildBackend {
            stopCaptureBackendLocked(reason: reason)
        }

        let format = makeCaptureFormat()
        prepareBundledPlaybackAssetLocked(outputFormat: format)
        prepareRawCaptureSegment(format: format)

        let backend = VoiceProcessingCaptureBackend(
            captureFormat: format,
            bufferHandler: { [weak self] buffer in
                self?.ingestCapturedBuffer(buffer)
            },
            playbackRenderer: { [weak self] buffer, frameCount in
                self?.bundledPlaybackController.fillOutput(buffer, frameCount: frameCount)
            },
            outputHandler: { [weak self] in
                self?.recordOutputRender()
            },
            errorHandler: { [weak self] message in
                self?.runtimeState.write { state in
                    state.lastError = message
                }
            }
        )

        do {
            try backend.start()
            captureBackend = backend
            let now = Date()
            let routeState = currentRouteState()
            runtimeState.write { state in
                state.engineIsRunning = true
                state.tapInstalled = true
                state.keepAliveOutputEnabled = true
                state.captureGraphKind = AudioCaptureBackendKind.voiceProcessingIOFullDuplex.rawValue
                state.captureBackendKind = AudioCaptureBackendKind.voiceProcessingIOFullDuplex.rawValue
                state.lastRestartAt = now
                state.lastRestartReason = reason
                state.lastKnownRoute = routeState.description
                state.hasInputRoute = routeState.hasInputRoute
                state.lastError = nil
                state.repairSuppressedReason = nil
                if reason != "initialStart" {
                    state.restartCount += 1
                }
            }
            syncBundledPlaybackRuntimeLocked()
        } catch {
            captureBackend = nil
            runtimeState.write { state in
                state.engineIsRunning = false
                state.tapInstalled = false
                state.keepAliveOutputEnabled = false
                state.lastError = error.localizedDescription
            }
            syncBundledPlaybackRuntimeLocked()
            throw error
        }
    }

    private func stopCaptureBackendLocked(reason: String) {
        captureBackend?.stop()
        captureBackend = nil
        runtimeState.write { state in
            state.engineIsRunning = false
            state.tapInstalled = false
            state.keepAliveOutputEnabled = false
            state.lastRestartReason = reason
        }
        syncBundledPlaybackRuntimeLocked()
    }

    private func stopCaptureAndDeactivateSession(clearSamples: Bool) {
        stopCaptureBackendLocked(reason: "stop")
        let routeState = currentRouteState()
        runtimeState.write { state in
            state.isSessionActive = false
            state.lastKnownRoute = routeState.description
            state.hasInputRoute = routeState.hasInputRoute
            state.frameFlowIsStalled = false
            state.lastObservedFrameGapSeconds = 0
            state.echoCancelledInputAvailable = false
            state.echoCancelledInputEnabled = false
        }

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            runtimeState.write { state in
                state.lastError = error.localizedDescription
            }
        }

        if clearSamples {
            samples.removeAll()
        }
    }

    private func prepareRawCaptureSegment(format: AVAudioFormat) {
        let sessionId = runtimeState.read { $0.sessionId }
        guard let sessionId else { return }

        let nextSegmentIndex = runtimeState.read { $0.rawCaptureSegmentCount + 1 }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SleepPOC-audio-\(sessionId.uuidString)-segment-\(nextSegmentIndex).caf")

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            rawCaptureStorage.write { storage in
                storage.currentFile = file
                storage.currentURL = url
                storage.urls.append(url)
            }
            runtimeState.write { state in
                state.rawCaptureSegmentCount = nextSegmentIndex
                state.activeRawCaptureFileName = url.lastPathComponent
                state.rawCaptureError = nil
            }
        } catch {
            rawCaptureStorage.write { storage in
                storage.currentFile = nil
                storage.currentURL = nil
            }
            runtimeState.write { state in
                state.rawCaptureError = "Failed to start raw capture: \(error.localizedDescription)"
                state.lastError = state.rawCaptureError
            }
        }
    }

    private func writeBufferToRawCapture(_ buffer: AVAudioPCMBuffer) {
        rawCaptureStorage.write { storage in
            guard let file = storage.currentFile else { return }
            do {
                try file.write(from: buffer)
            } catch {
                let message = "Raw capture write failed: \(error.localizedDescription)"
                runtimeState.write { state in
                    state.rawCaptureError = message
                    state.lastError = message
                }
            }
        }
    }

    private func cleanupRawCaptureFiles() {
        let urls = rawCaptureStorage.write { storage -> [URL] in
            let urls = storage.urls
            storage = RawCaptureStorage()
            return urls
        }

        urls.forEach { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func recordNonActivationError(_ error: Error) {
        let nsError = Self.unwrapNSError(from: error)
        let routeState = currentRouteState()
        runtimeState.write { state in
            state.lastError = error.localizedDescription
            state.lastKnownRoute = routeState.description
            state.hasInputRoute = routeState.hasInputRoute
            if case SensorProviderError.audioSessionFailed = error {
                state.lastActivationErrorDomain = nsError.domain
                state.lastActivationErrorCode = nsError.code
            }
        }
    }

    private func startCaptureWatchdogLocked() {
        guard captureWatchdogTimer == nil else { return }

        let watchdogInterval = DispatchTimeInterval.milliseconds(Int(Self.watchdogInterval * 1000))
        let timer = DispatchSource.makeTimerSource(queue: managementQueue)
        timer.schedule(
            deadline: .now() + watchdogInterval,
            repeating: watchdogInterval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.ensureCaptureRunningLocked(
                reason: "watchdogTick",
                allowSessionActivation: true,
                forceRebuildBackend: false
            )
        }
        captureWatchdogTimer = timer
        timer.resume()
    }

    private func stopCaptureWatchdogLocked() {
        captureWatchdogTimer?.cancel()
        captureWatchdogTimer = nil
    }

    @discardableResult
    private func updateFrameFlowHealthLocked(now: Date, reason: String) -> Bool {
        let routeState = currentRouteState()
        var isStalled = false

        runtimeState.write { state in
            state.lastKnownRoute = routeState.description
            state.hasInputRoute = routeState.hasInputRoute

            let referenceTime = state.lastFrameAt
                ?? state.lastRestartAt
                ?? state.lastSuccessfulActivationAt
                ?? state.lastActivationAttemptAt
            let gracePeriod = state.lastFrameAt == nil
                ? Self.initialFrameGracePeriod
                : Self.frameStallThreshold
            let gapSeconds = referenceTime.map { max(0, now.timeIntervalSince($0)) } ?? 0
            state.lastObservedFrameGapSeconds = gapSeconds

            let shouldConsiderStalled =
                state.wantsCapture &&
                state.isSessionActive &&
                state.engineIsRunning &&
                state.tapInstalled &&
                routeState.hasInputRoute &&
                referenceTime != nil &&
                gapSeconds >= gracePeriod

            if shouldConsiderStalled {
                isStalled = true
                if !state.frameFlowIsStalled {
                    state.frameFlowIsStalled = true
                    state.frameStallCount += 1
                    state.lastFrameStallAt = now
                    state.lastFrameStallReason = reason
                    state.lastError = "Audio frame flow stalled for \(Int(gapSeconds.rounded()))s while session remained active"
                }
            } else if state.frameFlowIsStalled {
                state.frameFlowIsStalled = false
                state.lastFrameRecoveryAt = now
                state.lastError = nil
            }
        }

        return isStalled
    }

    private func makeCaptureFormat() -> AVAudioFormat {
        let sampleRate = max(AVAudioSession.sharedInstance().sampleRate, 44_100)
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) ?? AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }

    private func currentRouteState() -> RouteState {
        let route = AVAudioSession.sharedInstance().currentRoute
        return RouteState(
            description: Self.routeDescription(for: route),
            hasInputRoute: !route.inputs.isEmpty
        )
    }

    private func syncEchoCancelledCapabilityLocked() {
        let audioSession = AVAudioSession.sharedInstance()
        let available: Bool
        let enabled: Bool
        if #available(iOS 18.2, *) {
            available = audioSession.isEchoCancelledInputAvailable
            enabled = audioSession.isEchoCancelledInputEnabled
        } else {
            available = false
            enabled = false
        }

        runtimeState.write { state in
            state.echoCancelledInputAvailable = available
            state.echoCancelledInputEnabled = enabled
        }
    }

    private func repairSuppressionReason(
        for snapshot: RuntimeState,
        recentlyAttemptedActivation: Bool
    ) -> String? {
        if recentlyAttemptedActivation {
            return "recentActivationThrottle"
        }

        let applicationState = DispatchQueue.main.sync {
            UIApplication.shared.applicationState
        }
        switch applicationState {
        case .active:
            return nil
        case .inactive:
            if !snapshot.hasInputRoute {
                return "inactiveWithoutInputRoute"
            }
            if !snapshot.isSessionActive {
                return "inactiveSessionInactive"
            }
            return nil
        case .background:
            if !snapshot.hasInputRoute {
                return "backgroundWithoutInputRoute"
            }
            if !snapshot.isSessionActive {
                return "backgroundSessionInactive"
            }
            return nil
        @unknown default:
            return "unknownApplicationState"
        }
    }

    private func markRepairDecisionLocked(_ decision: String, suppressedReason: String? = nil) {
        runtimeState.write { state in
            state.lastRepairDecision = decision
            state.repairSuppressedReason = suppressedReason
        }
    }

    private static func routeDescription(for route: AVAudioSessionRouteDescription) -> String {
        let inputs = route.inputs.isEmpty
            ? "none"
            : route.inputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
        let outputs = route.outputs.isEmpty
            ? "none"
            : route.outputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
        return "in[\(inputs)] out[\(outputs)]"
    }

    private static func activationContextLabel(for reason: String) -> String {
        if reason.contains("scenePhase:active") || reason == "initialStart" {
            return "foreground"
        }
        if reason.contains("scenePhase:inactive") {
            return "inactive"
        }
        if reason.contains("scenePhase:background") {
            return "background"
        }
        if reason.hasPrefix("interruption") {
            return "interruption"
        }
        if reason == "mediaServicesReset" {
            return "mediaServicesReset"
        }
        return "unknown"
    }

    private static func unwrapNSError(from error: Error) -> NSError {
        if case let SensorProviderError.audioSessionFailed(underlying) = error {
            return underlying as NSError
        }
        if case let SensorProviderError.audioEngineStartFailed(underlying) = error {
            return underlying as NSError
        }
        return error as NSError
    }

    private static func interruptionReasonLabel(for reason: AVAudioSession.InterruptionReason) -> String {
        switch reason {
        case .default:
            "default"
        case .appWasSuspended:
            "appWasSuspended"
        case .builtInMicMuted:
            "builtInMicMuted"
        case .routeDisconnected:
            "routeDisconnected"
        @unknown default:
            "unknownFutureInterruption"
        }
    }

    private static func routeChangeReasonLabel(for reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown:
            "unknown"
        case .newDeviceAvailable:
            "newDeviceAvailable"
        case .oldDeviceUnavailable:
            "oldDeviceUnavailable"
        case .categoryChange:
            "categoryChange"
        case .override:
            "override"
        case .wakeFromSleep:
            "wakeFromSleep"
        case .noSuitableRouteForCategory:
            "noSuitableRouteForCategory"
        case .routeConfigurationChange:
            "routeConfigurationChange"
        @unknown default:
            "unknownFutureRouteChange"
        }
    }
}

// MARK: - Permission Helper

enum PermissionHelper {
    static func microphoneGranted() -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    static func motionAvailable() -> Bool {
        let manager = CMMotionManager()
        return manager.isDeviceMotionAvailable || manager.isAccelerometerAvailable
    }
}
