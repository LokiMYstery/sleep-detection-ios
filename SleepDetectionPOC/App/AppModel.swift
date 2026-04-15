import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var currentSession: Session?
    @Published var sessionBundles: [SessionBundle] = []
    @Published var activePredictions: [RoutePrediction] = []
    @Published var recentWindows: [FeatureWindow] = []
    @Published var settings: ExperimentSettings = .default
    @Published var priorSnapshot: PriorSnapshot = .empty
    @Published var deviceCondition = DeviceCondition(
        hasWatch: false,
        watchReachable: false,
        hasHealthKitAccess: false,
        hasMicrophoneAccess: false,
        hasMotionAccess: false
    )
    @Published var summaryExportURL: URL?
    @Published var evaluationExportURL: URL?
    @Published var selectedSessionExportURL: URL?
    @Published var replayStatusMessage: String?
    @Published var lastError: AppError?
    @Published var isStartingSession = false
    @Published var watchRuntimeSnapshot: WatchRuntimeSnapshot = .unavailable
    @Published var watchSetupCompleted = false
    @Published var isPreparingWatch = false
    @Published var audioRuntimeSnapshot: AudioRuntimeSnapshot = .inactive

    let eventBus = EventBus.shared

    private let repository: SessionRepository
    private let settingsStore: SettingsStore
    private let healthKitService: LiveHealthKitService
    private let truthRefillService: TruthRefillService
    private let exportService: ExportService
    private let motionProvider: LiveMotionProvider
    private let interactionProvider: LiveInteractionProvider
    private let audioProvider: AudioProvider
    private let watchProvider: WatchProvider
    private let passivePhysiologyProvider: PassivePhysiologyProvider
    private let watchAutoStopDelaySeconds: TimeInterval

    private var routeRunner: RouteRunner?
    private var recordingTask: Task<Void, Never>?
    private var audioMonitoringTask: Task<Void, Never>?
    private var watchPollingTask: Task<Void, Never>?
    private var watchSetupPollingTask: Task<Void, Never>?
    private var physiologyPollingTask: Task<Void, Never>?
    private var eventSubscriptionID: UUID?
    private var nextWindowId = 0
    private var lastWindowBoundary: Date?
    private var hasBootstrapped = false
    private var lastWatchRuntimeSnapshot: WatchRuntimeSnapshot?
    private var lastAudioRuntimeSnapshot: AudioRuntimeSnapshot?
    private var sawWatchStartAck = false
    private var sawWatchWorkoutStarted = false
    private var sawWatchMirrorConnected = false
    private var sawFirstWatchWindow = false
    private var didEmitNoAckTimeout = false
    private var didEmitNoFirstPacketTimeout = false
    private var didEmitWatchCompanionMissing = false
    private var pendingWatchSessionStart = false
    private var hasIssuedWatchStartForCurrentSession = false
    private var lastIssuedWatchCommandKind: WatchSyncCommand.Command?
    private var watchStartCommandIssuedAt: Date?
    private var watchAutoStopTask: Task<Void, Never>?
    private var didAutoStopWatchForCurrentSession = false

    /// App-level error type for UI display
    struct AppError: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let title: String
        let message: String
        let severity: ErrorSeverity

        static func == (lhs: AppError, rhs: AppError) -> Bool {
            lhs.id == rhs.id
        }
    }

    init(
        repository: SessionRepository = FileSessionRepository(),
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        healthKitService: LiveHealthKitService = LiveHealthKitService(),
        motionProvider: LiveMotionProvider = LiveMotionProvider(),
        interactionProvider: LiveInteractionProvider = LiveInteractionProvider(),
        audioProvider: AudioProvider = LiveAudioProvider(),
        watchProvider: WatchProvider = LiveWatchProvider(),
        passivePhysiologyProvider: PassivePhysiologyProvider = LivePassivePhysiologyProvider(),
        watchAutoStopDelaySeconds: TimeInterval = 10 * 60
    ) {
        self.repository = repository
        self.settingsStore = settingsStore
        self.healthKitService = healthKitService
        self.truthRefillService = LiveTruthRefillService(healthKitService: healthKitService, repository: repository)
        self.exportService = LiveExportService(repository: repository)
        self.motionProvider = motionProvider
        self.interactionProvider = interactionProvider
        self.audioProvider = audioProvider
        self.watchProvider = watchProvider
        self.passivePhysiologyProvider = passivePhysiologyProvider
        self.watchAutoStopDelaySeconds = watchAutoStopDelaySeconds
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        settings = await settingsStore.load()
        watchSetupCompleted = await settingsStore.loadWatchSetupCompleted()
        deviceCondition = await healthKitService.detectDeviceCondition()

        let sleepSamples = (settings.disableHealthKitPriors || !deviceCondition.hasHealthKitAccess)
            ? []
            : await healthKitService.fetchRecentSleepSamples()
        let heartRateSamples = (settings.disableHealthKitPriors || !deviceCondition.hasHealthKitAccess)
            ? []
            : await healthKitService.fetchRecentHeartRateSamples()
        let hrvSamples = (settings.disableHealthKitPriors || !deviceCondition.hasHealthKitAccess)
            ? []
            : await healthKitService.fetchRecentHRVSamples()
        priorSnapshot = PriorComputer.compute(
            sleepSamples: sleepSamples,
            heartRateSamples: heartRateSamples,
            hrvSamples: hrvSamples,
            settings: settings,
            hasHealthKitAccess: deviceCondition.hasHealthKitAccess && !settings.disableHealthKitPriors
        )
        updateAudioRuntimeState(recordEvents: false)
        updateWatchRuntimeState(recordEvents: false)
        drainWatchDiagnostics(recordEvents: false)

        _ = try? await repository.recoverInterruptedSessions(now: Date())
        try? await truthRefillService.refillPendingTruths()
        await reloadBundles()
    }

    var watchSetupState: WatchSetupState {
        if !watchRuntimeSnapshot.isPaired {
            return .notPaired
        }
        if !watchRuntimeSnapshot.isWatchAppInstalled {
            return .notInstalled
        }
        if isWatchReadyForRealtime(watchRuntimeSnapshot) || watchSetupCompleted {
            return .ready
        }
        return .authorizationRequired
    }

    var watchSetupStatusText: String {
        if !watchRuntimeSnapshot.isPaired {
            return WatchSetupState.notPaired.rawValue
        }
        if !watchRuntimeSnapshot.isWatchAppInstalled {
            return WatchSetupState.notInstalled.rawValue
        }
        if isWatchReadyForRealtime(watchRuntimeSnapshot) || watchSetupCompleted {
            return WatchSetupState.ready.rawValue
        }
        if watchRuntimeSnapshot.runtimeState == .authorizationRequired {
            return WatchSetupState.authorizationRequired.rawValue
        }
        if isPreparingWatch {
            return "Preparing Watch"
        }
        return "Needs Preparation"
    }

    var watchSetupGuidance: String {
        switch watchSetupState {
        case .notPaired:
            return "Pair an Apple Watch with this iPhone first. Route E cannot run without a paired watch."
        case .notInstalled:
            return "Install the watch companion from the iPhone Watch app once. After that, use Prepare Watch to finish authorization."
        case .authorizationRequired:
            if watchRuntimeSnapshot.runtimeState == .authorizationRequired {
                return "Open the watch app and approve Health access once. After authorization, future starts can be initiated from iPhone."
            }
            if isPreparingWatch {
                return "Watch preparation is in progress. If nothing changes, open the watch app once and complete any pending authorization."
            }
            return "Run Prepare Watch once before the first realtime test so the watch app can authorize Health access."
        case .ready:
            return "Watch authorization is complete. You can start future recording sessions from iPhone."
        }
    }

    var canPrepareWatch: Bool {
        watchRuntimeSnapshot.isPaired &&
        watchRuntimeSnapshot.isWatchAppInstalled &&
        !isPreparingWatch &&
        !isWatchReadyForRealtime(watchRuntimeSnapshot) &&
        currentSession == nil
    }

    func handleScenePhase(_ phase: ScenePhase) async {
        let phaseLabel = scenePhaseLabel(for: phase)
        if currentSession != nil {
            postDiagnosticEvent(
                "system.scenePhaseChanged",
                payload: [
                    "phase": phaseLabel
                ]
            )
        }

        switch phase {
        case .active:
            if currentSession != nil {
                audioProvider.ensureRunning(reason: "scenePhase:\(phaseLabel)")
            }
            deviceCondition = await healthKitService.detectDeviceCondition()
            updateAudioRuntimeState(recordEvents: currentSession != nil)
            updateWatchRuntimeState(recordEvents: currentSession != nil)
            drainWatchDiagnostics(recordEvents: currentSession != nil)
            drainPassivePhysiologyDiagnostics(recordEvents: currentSession != nil)
            try? await truthRefillService.refillPendingTruths()
            await reloadBundles()
        case .inactive, .background:
            if currentSession != nil {
                await flushCurrentWindow(final: false)
                updateAudioRuntimeState(recordEvents: true)
            }
        default:
            break
        }
    }

    func markInteraction() {
        interactionProvider.markInteraction()
    }

    func startSession() async {
        guard currentSession == nil, !isStartingSession else { return }
        isStartingSession = true
        defer { isStartingSession = false }
        await bootstrapIfNeeded()
        if !settings.disableHealthKitPriors, !deviceCondition.hasHealthKitAccess {
            _ = await healthKitService.requestAuthorization()
        }
        if !settings.disableMicrophoneFeatures, !PermissionHelper.microphoneGranted() {
            _ = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        deviceCondition = await healthKitService.detectDeviceCondition()
        updateAudioRuntimeState(recordEvents: false)
        updateWatchRuntimeState(recordEvents: false)

        let start = Date()
        var sessionDeviceCondition = deviceCondition
        var disabledFeatures = settings.disableHealthKitPriors ? ["healthkitPriors"] : []
        var startupWarnings: [String] = []
        var session = Session.make(
            startTime: start,
            deviceCondition: sessionDeviceCondition,
            priorLevel: priorSnapshot.level,
            enabledRoutes: RouteId.allCases,
            disabledFeatures: disabledFeatures
        )
        session.status = .recording
        session.phonePlacement = settings.defaultPhonePlacement.rawValue

        do {
            try await repository.createSession(session)
            try interactionProvider.start(session: session)
        } catch {
            await reportError(
                title: "Failed to Start Session",
                message: error.localizedDescription,
                severity: .error
            )
            eventBus.post(RouteEvent(
                routeId: .A,
                eventType: "system.sessionStartFailed",
                payload: [
                    "error": error.localizedDescription,
                    "errorType": "Unknown"
                ]
            ))
            return
        }

        do {
            try motionProvider.start(session: session)
        } catch let error as SensorProviderError {
            sessionDeviceCondition.hasMotionAccess = false
            disabledFeatures.append("motionUnavailable")
            startupWarnings.append("Motion sensors unavailable. Route C and D may be limited.")
            eventBus.post(RouteEvent(
                routeId: .A,
                eventType: "system.sessionStartDegraded",
                payload: [
                    "provider": "motion",
                    "error": error.localizedDescription
                ]
            ))
        } catch {
            sessionDeviceCondition.hasMotionAccess = false
            disabledFeatures.append("motionUnavailable")
            startupWarnings.append("Motion sensors failed to start. Route C and D may be limited.")
            eventBus.post(RouteEvent(
                routeId: .A,
                eventType: "system.sessionStartDegraded",
                payload: [
                    "provider": "motion",
                    "error": error.localizedDescription
                ]
            ))
        }

        do {
            try audioProvider.start(session: session)
        } catch let error as SensorProviderError {
            sessionDeviceCondition.hasMicrophoneAccess = false
            disabledFeatures.append("microphoneUnavailable")
            startupWarnings.append("Microphone unavailable. Route D will be disabled for this session.")
            eventBus.post(RouteEvent(
                routeId: .A,
                eventType: "system.sessionStartDegraded",
                payload: [
                    "provider": "audio",
                    "error": error.localizedDescription
                ]
            ))
        } catch {
            sessionDeviceCondition.hasMicrophoneAccess = false
            disabledFeatures.append("microphoneUnavailable")
            startupWarnings.append("Microphone failed to start. Route D will be disabled for this session.")
            eventBus.post(RouteEvent(
                routeId: .A,
                eventType: "system.sessionStartDegraded",
                payload: [
                    "provider": "audio",
                    "error": error.localizedDescription
                ]
            ))
        }

        let initialWatchSnapshot = watchProvider.runtimeSnapshot()
        sessionDeviceCondition.hasWatch = initialWatchSnapshot.isPaired
        sessionDeviceCondition.watchReachable = initialWatchSnapshot.isReachable

        if !initialWatchSnapshot.isPaired {
            disabledFeatures.append("watchUnavailable")
            startupWarnings.append("Apple Watch is not paired. Route E will remain unavailable for this session.")
            eventBus.post(RouteEvent(
                routeId: .A,
                eventType: "system.sessionStartDegraded",
                payload: [
                    "provider": "watch",
                    "error": "notPaired"
                ]
            ))
        } else if !initialWatchSnapshot.isWatchAppInstalled {
            startupWarnings.append("Watch companion app is not installed. Route E will wait until the watch app is installed and prepared.")
            eventBus.post(RouteEvent(
                routeId: .A,
                eventType: "system.sessionStartDegraded",
                payload: [
                    "provider": "watch",
                    "error": "companionMissing"
                ]
            ))
        }

        do {
            try passivePhysiologyProvider.start(session: session)
        } catch {
            startupWarnings.append("HealthKit passive live provider failed to start. Route F may remain unavailable.")
            eventBus.post(RouteEvent(
                routeId: .F,
                eventType: "system.sessionStartDegraded",
                payload: [
                    "provider": "healthkitPassive",
                    "error": error.localizedDescription
                ]
            ))
        }

        updateAudioRuntimeState(recordEvents: false)
        drainPassivePhysiologyDiagnostics(recordEvents: false)
        session.deviceCondition = sessionDeviceCondition
        session.disabledFeatures = Array(NSOrderedSet(array: disabledFeatures)) as? [String] ?? disabledFeatures
        deviceCondition = sessionDeviceCondition
        try? await repository.updateSession(session)

        if !startupWarnings.isEmpty {
            await reportError(
                title: "Recording Started With Limited Sensors",
                message: startupWarnings.joined(separator: "\n"),
                severity: .warning
            )
        }

        currentSession = session
        recentWindows = []
        nextWindowId = 0
        lastWindowBoundary = start
        eventBus.reset()
        resetWatchStartupTracking()

        eventSubscriptionID = eventBus.subscribe { [weak self] event in
            guard let self, let sessionId = self.currentSession?.sessionId else { return }
            Task {
                try? await self.repository.appendEvent(event, to: sessionId)
            }
        }

        beginWatchRealtimeIfNeeded(for: session, recordEvents: true)
        updateAudioRuntimeState(recordEvents: true)
        updateWatchRuntimeState(recordEvents: true)
        drainWatchDiagnostics(recordEvents: true)
        drainPassivePhysiologyDiagnostics(recordEvents: true)

        postDiagnosticEvent(
            "system.sessionInitialized",
            payload: [
                "hasWatch": String(session.deviceCondition.hasWatch),
                "hasMotionAccess": String(session.deviceCondition.hasMotionAccess),
                "hasMicrophoneAccess": String(session.deviceCondition.hasMicrophoneAccess),
                "watchReachable": String(session.deviceCondition.watchReachable),
                "audioEngineRunning": String(audioRuntimeSnapshot.engineIsRunning),
                "audioTapInstalled": String(audioRuntimeSnapshot.tapInstalled),
                "audioRestartCount": "\(audioRuntimeSnapshot.restartCount)",
                "watchRuntimeState": watchRuntimeSnapshot.runtimeState.rawValue,
                "watchTransportMode": watchRuntimeSnapshot.transportMode.rawValue,
                "disabledFeatures": session.disabledFeatures.joined(separator: "|")
            ]
        )

        let runner = RouteRunner(engines: makeRouteEngines())
        routeRunner = runner
        runner.start(session: session, priors: priorSnapshot.routePriors)
        activePredictions = runner.currentPredictions()
        try? await repository.savePredictions(activePredictions, for: session.sessionId)
        postPredictionSnapshot()

        recordingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self.flushCurrentWindow(final: false)
            }
        }

        audioMonitoringTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self.audioProvider.ensureRunning(reason: "appAudioWatchdog")
                self.updateAudioRuntimeState(recordEvents: true)
            }
        }

        watchPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self.flushPendingWatchWindows()
            }
        }

        physiologyPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self.flushPendingPhysiologyWindows()
            }
        }
    }

    func stopSession() async {
        guard var session = currentSession else { return }

        recordingTask?.cancel()
        recordingTask = nil
        audioMonitoringTask?.cancel()
        audioMonitoringTask = nil
        watchPollingTask?.cancel()
        watchPollingTask = nil
        watchSetupPollingTask?.cancel()
        watchSetupPollingTask = nil
        physiologyPollingTask?.cancel()
        physiologyPollingTask = nil

        await flushPendingWatchWindows()
        await flushPendingPhysiologyWindows()
        await flushCurrentWindow(final: true)

        motionProvider.stop()
        interactionProvider.stop()
        audioProvider.stop()
        watchProvider.stop()
        passivePhysiologyProvider.stop()

        routeRunner?.stop()
        routeRunner = nil

        session.endTime = Date()
        session.status = .pendingTruth
        session.notes = session.interrupted ? "Recovered interrupted session" : session.notes

        try? await repository.updateSession(session)
        try? await repository.savePredictions(activePredictions, for: session.sessionId)
        try? await truthRefillService.refillPendingTruths()

        if let eventSubscriptionID {
            eventBus.unsubscribe(eventSubscriptionID)
            self.eventSubscriptionID = nil
        }

        currentSession = nil
        resetWatchStartupTracking()
        updateAudioRuntimeState(recordEvents: false)
        updateWatchRuntimeState(recordEvents: false)
        drainWatchDiagnostics(recordEvents: false)
        drainPassivePhysiologyDiagnostics(recordEvents: false)
        await reloadBundles()
    }

    func refreshTruths() async {
        try? await truthRefillService.refillPendingTruths()
        await reloadBundles()
    }

    func updateCurrentSessionPhonePlacement(_ placement: PhonePlacement) async {
        settings.defaultPhonePlacement = placement
        guard var session = currentSession else { return }
        session.phonePlacement = placement.rawValue
        currentSession = session
        try? await repository.updateSession(session)
    }

    func updateCurrentSessionNotes(_ notes: String) async {
        guard var session = currentSession else { return }
        session.notes = notes
        currentSession = session
        try? await repository.updateSession(session)
    }

    func saveSettings() async {
        await settingsStore.save(settings)
        deviceCondition = await healthKitService.detectDeviceCondition()
        let sleepSamples = (settings.disableHealthKitPriors || !deviceCondition.hasHealthKitAccess)
            ? []
            : await healthKitService.fetchRecentSleepSamples()
        let heartRateSamples = (settings.disableHealthKitPriors || !deviceCondition.hasHealthKitAccess)
            ? []
            : await healthKitService.fetchRecentHeartRateSamples()
        let hrvSamples = (settings.disableHealthKitPriors || !deviceCondition.hasHealthKitAccess)
            ? []
            : await healthKitService.fetchRecentHRVSamples()
        priorSnapshot = PriorComputer.compute(
            sleepSamples: sleepSamples,
            heartRateSamples: heartRateSamples,
            hrvSamples: hrvSamples,
            settings: settings,
            hasHealthKitAccess: deviceCondition.hasHealthKitAccess && !settings.disableHealthKitPriors
        )
    }

    func requestHealthKitAccess() async {
        guard !settings.disableHealthKitPriors else { return }
        let granted = await healthKitService.requestAuthorization()
        deviceCondition = await healthKitService.detectDeviceCondition()
        let sleepSamples = granted ? await healthKitService.fetchRecentSleepSamples() : []
        let heartRateSamples = granted ? await healthKitService.fetchRecentHeartRateSamples() : []
        let hrvSamples = granted ? await healthKitService.fetchRecentHRVSamples() : []
        priorSnapshot = PriorComputer.compute(
            sleepSamples: sleepSamples,
            heartRateSamples: heartRateSamples,
            hrvSamples: hrvSamples,
            settings: settings,
            hasHealthKitAccess: deviceCondition.hasHealthKitAccess && !settings.disableHealthKitPriors
        )
        if !granted {
            await reportError(
                title: "HealthKit Access Not Granted",
                message: "Sleep history and heart-rate priors remain unavailable. You can enable access later in the Health app or iPhone Settings.",
                severity: .warning
            )
        }
    }

    func requestMicrophoneAccess() async {
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        deviceCondition = await healthKitService.detectDeviceCondition()
        if !granted {
            await reportError(
                title: "Microphone Access Not Granted",
                message: "Route D needs microphone-derived features. Recording can still start, but Route D will be unavailable.",
                severity: .warning
            )
        }
    }

    func setBundledPlaybackEnabled(_ enabled: Bool) async {
        guard currentSession != nil else { return }
        audioProvider.setBundledPlaybackEnabled(enabled)
        updateAudioRuntimeState(recordEvents: true)

        eventBus.post(
            RouteEvent(
                routeId: .D,
                eventType: "custom.audioBundledPlaybackToggled",
                payload: [
                    "enabled": String(audioRuntimeSnapshot.bundledPlaybackEnabled),
                    "available": String(audioRuntimeSnapshot.bundledPlaybackAvailable),
                    "assetName": audioRuntimeSnapshot.bundledPlaybackAssetName ?? "",
                    "error": audioRuntimeSnapshot.bundledPlaybackError ?? ""
                ]
            )
        )
    }

    func prepareWatch() async {
        await bootstrapIfNeeded()
        updateWatchRuntimeState(recordEvents: true)
        drainWatchDiagnostics(recordEvents: true)

        let snapshot = watchRuntimeSnapshot
        guard snapshot.isPaired else {
            emitWatchSetupBlocked(reason: "notPaired", snapshot: snapshot)
            return
        }
        guard snapshot.isWatchAppInstalled else {
            emitWatchSetupBlocked(reason: "notInstalled", snapshot: snapshot)
            return
        }
        guard !isWatchReadyForRealtime(snapshot), !watchSetupCompleted else {
            isPreparingWatch = false
            stopWatchSetupPolling()
            return
        }

        let sessionId = currentSession?.sessionId ?? UUID()
        beginWatchPrepareFlow(sessionId: sessionId, recordEvents: true)
    }

    func exportSummary() async {
        summaryExportURL = try? await exportService.exportSummaryCSV()
    }

    func exportEvaluation() async {
        evaluationExportURL = try? await exportService.exportEvaluationJSON()
    }

    func exportSession(_ sessionId: UUID) async {
        selectedSessionExportURL = try? await exportService.exportSessionJSON(sessionId: sessionId)
    }

    func replayRouteC(sessionId: UUID) async {
        await replayRoute(.C, sessionId: sessionId)
    }

    func replayRouteD(sessionId: UUID) async {
        await replayRoute(.D, sessionId: sessionId)
    }

    private func replayRoute(_ routeId: RouteId, sessionId: UUID) async {
        guard let bundle = try? await repository.loadBundle(sessionId: sessionId) else {
            replayStatusMessage = "Replay failed: missing session"
            return
        }

        guard let engine = makeReplayEngine(routeId: routeId) else {
            replayStatusMessage = "Replay for Route \(routeId.rawValue) is not supported yet"
            return
        }
        engine.start(session: bundle.session, priors: priorSnapshot.routePriors)
        bundle.windows.forEach { engine.onWindow($0) }

        guard let replayedPrediction = engine.currentPrediction() else {
            replayStatusMessage = "Replay finished but Route \(routeId.rawValue) produced no result"
            return
        }

        let previousPrediction = bundle.predictions.byRoute[routeId]
        var updatedPredictions = bundle.predictions.filter { $0.routeId != routeId }
        updatedPredictions.append(replayedPrediction)
        updatedPredictions.sort { $0.routeId.rawValue < $1.routeId.rawValue }
        try? await repository.savePredictions(updatedPredictions, for: sessionId)

        if let truthDate = bundle.truth?.healthKitSleepOnset {
            let updatedTruth = TruthRecord(
                hasTruth: bundle.truth?.hasTruth ?? true,
                healthKitSleepOnset: truthDate,
                healthKitSource: bundle.truth?.healthKitSource,
                retrievedAt: bundle.truth?.retrievedAt ?? Date(),
                errors: TruthEvaluator.computeErrors(
                    truthDate: truthDate,
                    predictions: updatedPredictions
                )
            )
            try? await repository.saveTruth(updatedTruth, for: sessionId)
        }

        replayStatusMessage = replayMessage(
            routeId: routeId,
            sessionDate: bundle.session.date,
            previousPrediction: previousPrediction,
            newPrediction: replayedPrediction
        )
        await reloadBundles()
    }

    private func reloadBundles() async {
        sessionBundles = (try? await repository.loadBundles()) ?? []
    }

    private func isWatchReadyForRealtime(_ snapshot: WatchRuntimeSnapshot) -> Bool {
        snapshot.runtimeState == .readyForRealtime ||
        snapshot.runtimeState == .workoutStarted ||
        snapshot.runtimeState == .mirrorConnected
    }

    private func persistWatchSetupCompleted(_ completed: Bool) {
        guard watchSetupCompleted != completed else { return }
        watchSetupCompleted = completed
        Task {
            await settingsStore.saveWatchSetupCompleted(completed)
        }
    }

    private func syncWatchSetupCompletion(with snapshot: WatchRuntimeSnapshot) {
        if !snapshot.isPaired || !snapshot.isWatchAppInstalled || snapshot.runtimeState == .authorizationRequired {
            persistWatchSetupCompleted(false)
            return
        }
        if isWatchReadyForRealtime(snapshot) {
            persistWatchSetupCompleted(true)
        }
    }

    private func emitWatchSetupBlocked(reason: String, snapshot: WatchRuntimeSnapshot) {
        eventBus.post(
            RouteEvent(
                routeId: .E,
                eventType: "custom.watchSetupBlocked",
                payload: [
                    "reason": reason,
                    "activationState": snapshot.activationState.rawValue,
                    "runtimeState": snapshot.runtimeState.rawValue,
                    "transportMode": snapshot.transportMode.rawValue,
                    "isReachable": String(snapshot.isReachable),
                    "lastError": snapshot.lastError ?? ""
                ]
            )
        )
    }

    private func startWatchSetupPolling(recordEvents: Bool) {
        watchSetupPollingTask?.cancel()
        watchSetupPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if self.currentSession != nil {
                    await self.flushPendingWatchWindows()
                } else {
                    self.updateWatchRuntimeState(recordEvents: recordEvents)
                    self.drainWatchDiagnostics(recordEvents: recordEvents)
                }
                if !self.isPreparingWatch && !self.pendingWatchSessionStart {
                    self.watchSetupPollingTask = nil
                    return
                }
            }
        }
    }

    private func stopWatchSetupPolling() {
        watchSetupPollingTask?.cancel()
        watchSetupPollingTask = nil
    }

    private func beginWatchPrepareFlow(sessionId: UUID, recordEvents: Bool) {
        isPreparingWatch = true
        lastIssuedWatchCommandKind = .prepareRuntime
        startWatchSetupPolling(recordEvents: recordEvents)

        do {
            try watchProvider.prepareRuntime(sessionId: sessionId)
            updateWatchRuntimeState(recordEvents: recordEvents)
            drainWatchDiagnostics(recordEvents: recordEvents)
        } catch {
            isPreparingWatch = false
            pendingWatchSessionStart = false
            stopWatchSetupPolling()
            let snapshot = watchProvider.runtimeSnapshot()
            emitWatchSetupBlocked(reason: "prepareFailed", snapshot: snapshot)
            Task {
                await reportError(
                    title: "Prepare Watch Failed",
                    message: error.localizedDescription,
                    severity: .warning
                )
            }
        }
    }

    private func issueWatchStartIfNeeded(for session: Session, recordEvents: Bool) {
        guard !hasIssuedWatchStartForCurrentSession else { return }
        let commandIssuedAt = Date()
        resetWatchStartCommandTracking()
        lastIssuedWatchCommandKind = .startSession

        do {
            try watchProvider.start(session: session)
            hasIssuedWatchStartForCurrentSession = true
            pendingWatchSessionStart = false
            isPreparingWatch = false
            watchStartCommandIssuedAt = commandIssuedAt
            updateWatchRuntimeState(recordEvents: recordEvents)
            drainWatchDiagnostics(recordEvents: recordEvents)
            stopWatchSetupPolling()
        } catch {
            hasIssuedWatchStartForCurrentSession = false
            pendingWatchSessionStart = false
            isPreparingWatch = false
            stopWatchSetupPolling()
            let snapshot = watchProvider.runtimeSnapshot()
            emitWatchSetupBlocked(reason: "startFailed", snapshot: snapshot)
            Task {
                await reportError(
                    title: "Watch Start Failed",
                    message: error.localizedDescription,
                    severity: .warning
                )
            }
        }
    }

    private func beginWatchRealtimeIfNeeded(for session: Session, recordEvents: Bool) {
        let snapshot = watchProvider.runtimeSnapshot()
        applyWatchRuntimeSnapshot(snapshot, recordEvents: recordEvents)
        drainWatchDiagnostics(recordEvents: recordEvents)

        guard snapshot.isPaired else {
            pendingWatchSessionStart = false
            isPreparingWatch = false
            stopWatchSetupPolling()
            emitWatchSetupBlocked(reason: "notPaired", snapshot: snapshot)
            return
        }

        guard snapshot.isWatchAppInstalled else {
            pendingWatchSessionStart = false
            isPreparingWatch = false
            stopWatchSetupPolling()
            emitWatchSetupBlocked(reason: "notInstalled", snapshot: snapshot)
            return
        }

        let shouldUseDirectStartBootstrap =
            watchSetupCompleted &&
            snapshot.runtimeState != .authorizationRequired

        if isWatchReadyForRealtime(snapshot) || shouldUseDirectStartBootstrap {
            issueWatchStartIfNeeded(for: session, recordEvents: recordEvents)
            return
        }

        pendingWatchSessionStart = true
        hasIssuedWatchStartForCurrentSession = false
        beginWatchPrepareFlow(sessionId: session.sessionId, recordEvents: recordEvents)
    }

    private func flushCurrentWindow(final: Bool) async {
        guard let session = currentSession else { return }
        let end = Date()
        let start = lastWindowBoundary ?? session.startTime
        guard end > start else { return }

        let duration = end.timeIntervalSince(start)
        let motion = motionProvider.drainMotionFeatures(windowDuration: duration)
        let audio = audioProvider.consumeWindow(windowDuration: duration)
        updateAudioRuntimeState(recordEvents: true)
        let interaction = interactionProvider.consumeWindow(now: end)
        let window = FeatureWindow(
            windowId: nextWindowId,
            startTime: start,
            endTime: end,
            duration: duration,
            source: .iphone,
            motion: motion,
            audio: audio,
            interaction: interaction,
            watch: nil
        )

        postDiagnosticEvent(
            "system.windowPrepared",
            payload: diagnosticPayload(for: window, final: final)
        )
        if window.source == .iphone, window.duration > 90 {
            postDiagnosticEvent(
                "system.windowOversized",
                payload: [
                    "windowId": "\(window.windowId)",
                    "durationSec": String(format: "%.1f", window.duration),
                    "startTime": window.startTime.csvTimestamp,
                    "endTime": window.endTime.csvTimestamp
                ]
            )
        }

        nextWindowId += 1
        lastWindowBoundary = end
        await processWindow(window, sessionId: session.sessionId)

        if final, let eventSubscriptionID {
            eventBus.unsubscribe(eventSubscriptionID)
            self.eventSubscriptionID = nil
        }
    }

    private func flushPendingWatchWindows() async {
        guard let sessionId = currentSession?.sessionId else { return }
        let watchWindows = watchProvider.drainPendingWindows()
        guard !watchWindows.isEmpty else {
            updateWatchRuntimeState(recordEvents: true)
            drainWatchDiagnostics(recordEvents: true)
            return
        }

        for window in watchWindows {
            await processWindow(window, sessionId: sessionId)
        }
        updateWatchRuntimeState(recordEvents: true)
        drainWatchDiagnostics(recordEvents: true)
    }

    private func flushPendingPhysiologyWindows() async {
        guard let sessionId = currentSession?.sessionId else { return }
        let physiologyWindows = passivePhysiologyProvider.drainPendingWindows()
        guard !physiologyWindows.isEmpty else {
            drainPassivePhysiologyDiagnostics(recordEvents: true)
            return
        }

        for window in physiologyWindows {
            await processWindow(window, sessionId: sessionId)
        }
        drainPassivePhysiologyDiagnostics(recordEvents: true)
    }

    private func processWindow(_ window: FeatureWindow, sessionId: UUID) async {
        if window.source == .watch, Date().timeIntervalSince(window.endTime) > 4 * 60 {
            eventBus.post(
                RouteEvent(
                    routeId: .E,
                    eventType: "custom.watchDataBackfill",
                    payload: [
                        "windowRange": "\(window.startTime.csvTimestamp)->\(window.endTime.csvTimestamp)",
                        "sampleCount": window.watch?.heartRate.map { _ in "1" } ?? "0"
                    ]
                )
            )
        }
        if window.source == .watch {
            sawFirstWatchWindow = true
        }
        recentWindows = Array(([window] + recentWindows).prefix(20))

        // Handle repository errors with proper logging
        do {
            try await repository.appendWindow(window, to: sessionId)
        } catch {
            await reportError(
                title: "Failed to Save Window",
                message: "Could not append window #\(window.windowId) to session: \(error.localizedDescription)",
                severity: .error
            )
            eventBus.post(RouteEvent(
                routeId: .A,
                eventType: "system.repositoryError",
                payload: [
                    "operation": "appendWindow",
                    "windowId": "\(window.windowId)",
                    "error": error.localizedDescription
                ]
            ))
        }

        let previousRouteEPrediction = activePredictions.first { $0.routeId == .E }
        routeRunner?.process(window: window)
        activePredictions = routeRunner?.currentPredictions() ?? activePredictions
        syncWatchAutoStopState(previousRouteEPrediction: previousRouteEPrediction, sessionId: sessionId)
        postPredictionSnapshot()

        // Handle prediction save errors
        do {
            try await repository.savePredictions(activePredictions, for: sessionId)
        } catch {
            await reportError(
                title: "Failed to Save Predictions",
                message: "Could not save predictions: \(error.localizedDescription)",
                severity: .warning
            )
        }
    }

    private func updateWatchRuntimeState(recordEvents: Bool) {
        applyWatchRuntimeSnapshot(watchProvider.runtimeSnapshot(), recordEvents: recordEvents)
    }

    private func syncWatchAutoStopState(previousRouteEPrediction: RoutePrediction?, sessionId: UUID) {
        guard currentSession?.sessionId == sessionId else { return }
        guard let routeEPrediction = activePredictions.first(where: { $0.routeId == .E }) else {
            cancelWatchAutoStop(reason: "routeEMissing")
            return
        }

        if routeEPrediction.confidence == .confirmed {
            guard previousRouteEPrediction?.confidence != .confirmed else { return }
            guard !didAutoStopWatchForCurrentSession else { return }
            guard watchAutoStopTask == nil else { return }
            scheduleWatchAutoStop(for: sessionId, prediction: routeEPrediction)
            return
        }

        cancelWatchAutoStop(reason: "routeENotConfirmed")
    }

    private func scheduleWatchAutoStop(for sessionId: UUID, prediction: RoutePrediction) {
        let delaySeconds = max(watchAutoStopDelaySeconds, 0)
        eventBus.post(
            RouteEvent(
                routeId: .E,
                eventType: "custom.watchAutoStopScheduled",
                payload: [
                    "sessionId": sessionId.uuidString,
                    "delaySec": "\(Int(delaySeconds.rounded()))",
                    "predictedTime": prediction.predictedSleepOnset.map { ISO8601DateFormatter.cached.string(from: $0) } ?? ""
                ]
            )
        )

        watchAutoStopTask = Task { [weak self] in
            if delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.executeWatchAutoStopIfNeeded(for: sessionId)
        }
    }

    private func executeWatchAutoStopIfNeeded(for sessionId: UUID) async {
        defer { watchAutoStopTask = nil }

        guard currentSession?.sessionId == sessionId else { return }
        guard !didAutoStopWatchForCurrentSession else { return }
        guard let routeEPrediction = activePredictions.first(where: { $0.routeId == .E }),
              routeEPrediction.confidence == .confirmed else {
            eventBus.post(
                RouteEvent(
                    routeId: .E,
                    eventType: "custom.watchAutoStopCancelled",
                    payload: [
                        "sessionId": sessionId.uuidString,
                        "reason": "routeENotConfirmedAtDeadline"
                    ]
                )
            )
            return
        }

        watchProvider.stop()
        didAutoStopWatchForCurrentSession = true

        eventBus.post(
            RouteEvent(
                routeId: .E,
                eventType: "custom.watchAutoStopped",
                payload: [
                    "sessionId": sessionId.uuidString,
                    "delaySec": "\(Int(max(watchAutoStopDelaySeconds, 0).rounded()))",
                    "predictedTime": routeEPrediction.predictedSleepOnset.map { ISO8601DateFormatter.cached.string(from: $0) } ?? ""
                ]
            )
        )
    }

    private func cancelWatchAutoStop(reason: String, emitEvent: Bool = true) {
        guard watchAutoStopTask != nil else { return }
        watchAutoStopTask?.cancel()
        watchAutoStopTask = nil

        guard emitEvent, let sessionId = currentSession?.sessionId else { return }
        eventBus.post(
            RouteEvent(
                routeId: .E,
                eventType: "custom.watchAutoStopCancelled",
                payload: [
                    "sessionId": sessionId.uuidString,
                    "reason": reason
                ]
            )
        )
    }

    private func resetWatchAutoStopState() {
        cancelWatchAutoStop(reason: "reset", emitEvent: false)
        didAutoStopWatchForCurrentSession = false
    }

    private func applyWatchRuntimeSnapshot(_ snapshot: WatchRuntimeSnapshot, recordEvents: Bool) {
        let previous = lastWatchRuntimeSnapshot

        watchRuntimeSnapshot = snapshot
        deviceCondition.hasWatch = snapshot.isPaired
        deviceCondition.watchReachable = snapshot.isReachable

        if var session = currentSession {
            session.deviceCondition.hasWatch = snapshot.isPaired
            session.deviceCondition.watchReachable = snapshot.isReachable
            currentSession = session
        }

        syncWatchStartupFlags(with: snapshot)
        syncWatchSetupCompletion(with: snapshot)

        if snapshot.runtimeState == .authorizationRequired {
            isPreparingWatch = true
        }
        if isWatchReadyForRealtime(snapshot) || snapshot.runtimeState == .stopped {
            isPreparingWatch = false
        }
        if !snapshot.isPaired || !snapshot.isWatchAppInstalled {
            isPreparingWatch = false
            pendingWatchSessionStart = false
        }

        let shouldAutoStartCurrentSession =
            recordEvents &&
            currentSession != nil &&
            pendingWatchSessionStart &&
            !hasIssuedWatchStartForCurrentSession &&
            isWatchReadyForRealtime(snapshot)

        guard recordEvents else {
            lastWatchRuntimeSnapshot = snapshot
            return
        }

        if previous != snapshot {
            postDiagnosticEvent("system.watchRuntimeSnapshot", payload: snapshot.eventPayload)
        }

        if snapshot.isPaired, !snapshot.isWatchAppInstalled, !didEmitWatchCompanionMissing {
            didEmitWatchCompanionMissing = true
            eventBus.post(
                RouteEvent(
                    routeId: .E,
                    eventType: "custom.watchCompanionMissing",
                    payload: [
                        "activationState": snapshot.activationState.rawValue,
                        "runtimeState": snapshot.runtimeState.rawValue,
                        "transportMode": snapshot.transportMode.rawValue,
                        "isReachable": String(snapshot.isReachable)
                    ]
                )
            )
        } else if snapshot.isWatchAppInstalled {
            didEmitWatchCompanionMissing = false
        }

        if previous?.runtimeState != .launchRequested, snapshot.runtimeState == .launchRequested {
            eventBus.post(
                RouteEvent(
                    routeId: .E,
                    eventType: "custom.watchLaunchRequested",
                    payload: [
                        "transportMode": snapshot.transportMode.rawValue
                    ]
                )
            )
        }

        if previous?.lastCommandAt != snapshot.lastCommandAt, let lastCommandAt = snapshot.lastCommandAt {
            switch lastIssuedWatchCommandKind {
            case .prepareRuntime:
                eventBus.post(
                    RouteEvent(
                        routeId: .E,
                        eventType: "custom.watchSetupStarted",
                        payload: [
                            "time": lastCommandAt.csvTimestamp,
                            "transportMode": snapshot.transportMode.rawValue
                        ]
                    )
                )
            case .startSession:
                eventBus.post(
                    RouteEvent(
                        routeId: .E,
                        eventType: "custom.watchStartCommandSent",
                        payload: [
                            "time": lastCommandAt.csvTimestamp,
                            "transportMode": snapshot.transportMode.rawValue
                        ]
                    )
                )
            case .stopSession, .none:
                break
            }
        }

        if previous?.lastAckAt != snapshot.lastAckAt,
           let lastAckAt = snapshot.lastAckAt,
           lastIssuedWatchCommandKind == .startSession {
            eventBus.post(
                RouteEvent(
                    routeId: .E,
                    eventType: "custom.watchStartAcked",
                    payload: [
                        "time": lastAckAt.csvTimestamp,
                        "transportMode": snapshot.transportMode.rawValue
                    ]
                )
            )
        }

        if previous?.runtimeState != snapshot.runtimeState {
            switch snapshot.runtimeState {
            case .readyForRealtime:
                eventBus.post(
                    RouteEvent(
                        routeId: .E,
                        eventType: "custom.watchSetupReady",
                        payload: [
                            "transportMode": snapshot.transportMode.rawValue
                        ]
                    )
                )
            case .workoutStarted:
                eventBus.post(
                    RouteEvent(
                        routeId: .E,
                        eventType: "custom.watchWorkoutStarted",
                        payload: [
                            "transportMode": snapshot.transportMode.rawValue
                        ]
                    )
                )
            case .authorizationRequired:
                eventBus.post(
                    RouteEvent(
                        routeId: .E,
                        eventType: "custom.watchAuthorizationRequired",
                        payload: [
                            "transportMode": snapshot.transportMode.rawValue,
                            "lastError": snapshot.lastError ?? "HealthKit authorization required on watch."
                        ]
                    )
                )
            case .workoutFailed:
                eventBus.post(
                    RouteEvent(
                        routeId: .E,
                        eventType: "custom.watchWorkoutFailed",
                        payload: [
                            "transportMode": snapshot.transportMode.rawValue,
                            "lastError": snapshot.lastError ?? "unknown"
                        ]
                    )
                )
            case .mirrorConnected:
                eventBus.post(
                    RouteEvent(
                        routeId: .E,
                        eventType: "custom.watchMirrorConnected",
                        payload: [
                            "transportMode": snapshot.transportMode.rawValue
                        ]
                    )
                )
            case .mirrorDisconnected:
                eventBus.post(
                    RouteEvent(
                        routeId: .E,
                        eventType: "custom.watchMirrorDisconnected",
                        payload: [
                            "transportMode": snapshot.transportMode.rawValue,
                            "lastError": snapshot.lastError ?? ""
                        ]
                    )
                )
            default:
                break
            }
        } else if previous?.transportMode != .mirroredWorkoutSession,
                  snapshot.transportMode == .mirroredWorkoutSession {
            eventBus.post(
                RouteEvent(
                    routeId: .E,
                    eventType: "custom.watchMirrorConnected",
                    payload: [
                        "transportMode": snapshot.transportMode.rawValue
                    ]
                )
            )
        }

        evaluateWatchStartupTimeouts(now: Date(), snapshot: snapshot)
        lastWatchRuntimeSnapshot = snapshot

        if shouldAutoStartCurrentSession, let session = currentSession {
            issueWatchStartIfNeeded(for: session, recordEvents: true)
        }

        if !isPreparingWatch && !pendingWatchSessionStart {
            stopWatchSetupPolling()
        }
    }

    private func updateAudioRuntimeState(recordEvents: Bool) {
        let snapshot = audioProvider.runtimeSnapshot()
        let previous = lastAudioRuntimeSnapshot

        audioRuntimeSnapshot = snapshot

        guard recordEvents else {
            lastAudioRuntimeSnapshot = snapshot
            return
        }

        if previous != snapshot {
            postDiagnosticEvent("system.audioRuntimeSnapshot", payload: snapshot.eventPayload)
        }

        if previous?.restartCount != snapshot.restartCount, snapshot.restartCount > 0 {
            eventBus.post(
                RouteEvent(
                    routeId: .D,
                    eventType: "custom.audioCaptureRestarted",
                    payload: [
                        "restartCount": "\(snapshot.restartCount)",
                        "reason": snapshot.lastRestartReason ?? "unknown",
                        "lastFrameAt": snapshot.lastFrameAt?.csvTimestamp ?? ""
                    ]
                )
            )
            eventBus.post(
                RouteEvent(
                    routeId: .D,
                    eventType: "custom.audioBackendRestarted",
                    payload: [
                        "restartCount": "\(snapshot.restartCount)",
                        "reason": snapshot.lastRestartReason ?? "unknown",
                        "backend": snapshot.captureBackendKind,
                        "strategy": snapshot.sessionStrategy,
                        "lastFrameAt": snapshot.lastFrameAt?.csvTimestamp ?? ""
                    ]
                )
            )
        }

        if (previous?.consecutiveEmptyWindows ?? 0) < 2, snapshot.consecutiveEmptyWindows >= 2 {
            eventBus.post(
                RouteEvent(
                    routeId: .D,
                    eventType: "custom.audioCaptureStalled",
                    payload: [
                        "emptyWindowStreak": "\(snapshot.consecutiveEmptyWindows)",
                        "lastFrameAt": snapshot.lastFrameAt?.csvTimestamp ?? ""
                    ]
                )
            )
        }

        if (previous?.frameStallCount ?? 0) < snapshot.frameStallCount {
            eventBus.post(
                RouteEvent(
                    routeId: .D,
                    eventType: "custom.audioFrameFlowStalled",
                    payload: [
                        "frameStallCount": "\(snapshot.frameStallCount)",
                        "reason": snapshot.lastFrameStallReason ?? "unknown",
                        "gapSeconds": String(format: "%.2f", snapshot.lastObservedFrameGapSeconds),
                        "lastFrameAt": snapshot.lastFrameAt?.csvTimestamp ?? "",
                        "route": snapshot.lastKnownRoute ?? "",
                        "captureGraphKind": snapshot.captureGraphKind,
                        "keepAliveOutputEnabled": String(snapshot.keepAliveOutputEnabled)
                    ]
                )
            )
        }

        if previous?.frameFlowIsStalled == true, snapshot.frameFlowIsStalled == false {
            eventBus.post(
                RouteEvent(
                    routeId: .D,
                    eventType: "custom.audioFrameFlowRestored",
                    payload: [
                        "lastFrameAt": snapshot.lastFrameAt?.csvTimestamp ?? "",
                        "recoveredAt": snapshot.lastFrameRecoveryAt?.csvTimestamp ?? "",
                        "route": snapshot.lastKnownRoute ?? "",
                        "captureGraphKind": snapshot.captureGraphKind,
                        "keepAliveOutputEnabled": String(snapshot.keepAliveOutputEnabled)
                    ]
                )
            )
        }

        if (previous?.routeLossWhileSessionActiveCount ?? 0) < snapshot.routeLossWhileSessionActiveCount {
            eventBus.post(
                RouteEvent(
                    routeId: .D,
                    eventType: "custom.audioInputRouteLost",
                    payload: [
                        "routeLossCount": "\(snapshot.routeLossWhileSessionActiveCount)",
                        "reason": snapshot.lastRouteLossReason ?? "unknown",
                        "route": snapshot.lastKnownRoute ?? "",
                        "lastFrameAt": snapshot.lastFrameAt?.csvTimestamp ?? "",
                        "captureGraphKind": snapshot.captureGraphKind
                    ]
                )
            )
        }

        if (previous?.hasInputRoute == false), snapshot.hasInputRoute {
            eventBus.post(
                RouteEvent(
                    routeId: .D,
                    eventType: "custom.audioInputRouteRestored",
                    payload: [
                        "route": snapshot.lastKnownRoute ?? "",
                        "lastFrameAt": snapshot.lastFrameAt?.csvTimestamp ?? "",
                        "captureGraphKind": snapshot.captureGraphKind
                    ]
                )
            )
        }

        if previous?.lastRepairDecision != snapshot.lastRepairDecision,
           let decision = snapshot.lastRepairDecision {
            if decision.hasPrefix("deferred") {
                eventBus.post(
                    RouteEvent(
                        routeId: .D,
                        eventType: "custom.audioRepairDeferred",
                        payload: [
                            "decision": decision,
                            "reason": snapshot.repairSuppressedReason ?? "",
                            "backend": snapshot.captureBackendKind,
                            "strategy": snapshot.sessionStrategy,
                            "route": snapshot.lastKnownRoute ?? "",
                            "activationContext": snapshot.lastActivationContext ?? ""
                        ]
                    )
                )
            } else if decision.hasPrefix("suppressed") {
                eventBus.post(
                    RouteEvent(
                        routeId: .D,
                        eventType: "custom.audioRepairSuppressed",
                        payload: [
                            "decision": decision,
                            "reason": snapshot.repairSuppressedReason ?? "",
                            "backend": snapshot.captureBackendKind,
                            "strategy": snapshot.sessionStrategy,
                            "route": snapshot.lastKnownRoute ?? "",
                            "activationContext": snapshot.lastActivationContext ?? ""
                        ]
                    )
                )
            }
        }

        if previous?.lastError != snapshot.lastError, let lastError = snapshot.lastError {
            eventBus.post(
                RouteEvent(
                    routeId: .D,
                    eventType: "custom.audioCaptureError",
                    payload: [
                        "error": lastError,
                        "captureGraphKind": snapshot.captureGraphKind,
                        "captureBackendKind": snapshot.captureBackendKind,
                        "sessionStrategy": snapshot.sessionStrategy,
                        "hasInputRoute": String(snapshot.hasInputRoute),
                        "activationReason": snapshot.lastActivationReason ?? "",
                        "activationContext": snapshot.lastActivationContext ?? "",
                        "activationErrorDomain": snapshot.lastActivationErrorDomain ?? "",
                        "activationErrorCode": snapshot.lastActivationErrorCode.map(String.init) ?? "",
                        "interruptionReason": snapshot.lastInterruptionReason ?? "",
                        "interruptionWasSuspended": String(snapshot.lastInterruptionWasSuspended),
                        "route": snapshot.lastKnownRoute ?? "",
                        "routeLossCount": "\(snapshot.routeLossWhileSessionActiveCount)",
                        "lastRouteLossReason": snapshot.lastRouteLossReason ?? "",
                        "frameFlowIsStalled": String(snapshot.frameFlowIsStalled),
                        "frameStallCount": "\(snapshot.frameStallCount)",
                        "lastFrameStallReason": snapshot.lastFrameStallReason ?? "",
                        "lastObservedFrameGapSeconds": String(format: "%.2f", snapshot.lastObservedFrameGapSeconds),
                        "keepAliveOutputEnabled": String(snapshot.keepAliveOutputEnabled),
                        "outputRenderCount": "\(snapshot.outputRenderCount)",
                        "lastOutputRenderAt": snapshot.lastOutputRenderAt?.csvTimestamp ?? "",
                        "framesSinceLastWindow": "\(snapshot.framesSinceLastWindow)",
                        "lastWindowFrameCount": "\(snapshot.lastWindowFrameCount)",
                        "aggregatedIOPreferenceEnabled": String(snapshot.aggregatedIOPreferenceEnabled),
                        "aggregatedIOPreferenceError": snapshot.aggregatedIOPreferenceError ?? "",
                        "rawCaptureSegmentCount": "\(snapshot.rawCaptureSegmentCount)",
                        "activeRawCaptureFileName": snapshot.activeRawCaptureFileName ?? "",
                        "rawCaptureError": snapshot.rawCaptureError ?? "",
                        "repairSuppressedReason": snapshot.repairSuppressedReason ?? "",
                        "lastRepairDecision": snapshot.lastRepairDecision ?? "",
                        "echoCancelledInputAvailable": String(snapshot.echoCancelledInputAvailable),
                        "echoCancelledInputEnabled": String(snapshot.echoCancelledInputEnabled)
                    ]
                )
            )
        }

        lastAudioRuntimeSnapshot = snapshot
    }

    private func resetWatchStartupTracking() {
        resetWatchAutoStopState()
        lastWatchRuntimeSnapshot = nil
        lastAudioRuntimeSnapshot = nil
        resetWatchStartCommandTracking()
        watchSetupPollingTask?.cancel()
        watchSetupPollingTask = nil
        isPreparingWatch = false
        pendingWatchSessionStart = false
        hasIssuedWatchStartForCurrentSession = false
        lastIssuedWatchCommandKind = nil
        didEmitWatchCompanionMissing = false
    }

    private func resetWatchStartCommandTracking() {
        sawWatchStartAck = false
        sawWatchWorkoutStarted = false
        sawWatchMirrorConnected = false
        sawFirstWatchWindow = false
        didEmitNoAckTimeout = false
        didEmitNoFirstPacketTimeout = false
        watchStartCommandIssuedAt = nil
    }

    private func drainWatchDiagnostics(recordEvents: Bool) {
        guard recordEvents else {
            _ = watchProvider.drainDiagnostics()
            return
        }

        for diagnostic in watchProvider.drainDiagnostics() {
            eventBus.post(diagnostic.event)
        }
    }

    private func drainPassivePhysiologyDiagnostics(recordEvents: Bool) {
        guard recordEvents else {
            _ = passivePhysiologyProvider.drainDiagnostics()
            return
        }

        for diagnostic in passivePhysiologyProvider.drainDiagnostics() {
            eventBus.post(diagnostic)
        }
    }

    private func syncWatchStartupFlags(with snapshot: WatchRuntimeSnapshot) {
        if snapshot.lastAckAt != nil {
            sawWatchStartAck = true
        }
        if snapshot.runtimeState == .workoutStarted {
            sawWatchWorkoutStarted = true
        }
        if snapshot.runtimeState == .mirrorConnected || snapshot.transportMode == .mirroredWorkoutSession {
            sawWatchMirrorConnected = true
        }
        if snapshot.lastWindowAt != nil {
            sawFirstWatchWindow = true
        }
    }

    private func evaluateWatchStartupTimeouts(now: Date, snapshot: WatchRuntimeSnapshot) {
        guard watchStartCommandIssuedAt != nil else { return }
        let elapsed = now.timeIntervalSince(watchStartCommandIssuedAt ?? now)

        if !didEmitNoAckTimeout, !sawWatchStartAck, elapsed >= 15 {
            didEmitNoAckTimeout = true
            eventBus.post(
                RouteEvent(
                    routeId: .E,
                    eventType: "custom.watchStartupTimeout",
                    payload: [
                        "reason": "noAck",
                        "elapsedSec": "\(Int(elapsed))",
                        "runtimeState": snapshot.runtimeState.rawValue,
                        "transportMode": snapshot.transportMode.rawValue
                    ]
                )
            )
        }

        if !didEmitNoFirstPacketTimeout,
           !sawWatchWorkoutStarted,
           !sawWatchMirrorConnected,
           !sawFirstWatchWindow,
           snapshot.runtimeState != .authorizationRequired,
           elapsed >= 150 {
            didEmitNoFirstPacketTimeout = true
            eventBus.post(
                RouteEvent(
                    routeId: .E,
                    eventType: "custom.watchStartupTimeout",
                    payload: [
                        "reason": "noFirstPacket",
                        "elapsedSec": "\(Int(elapsed))",
                        "runtimeState": snapshot.runtimeState.rawValue,
                        "transportMode": snapshot.transportMode.rawValue
                    ]
                )
            )
        }
    }

    private func makeRouteEngines() -> [RouteEngine] {
        [
            RouteAEngine(settings: settings),
            RouteBEngine(settings: settings),
            RouteCEngine(settings: settings),
            RouteDEngine(settings: settings),
            RouteEEngine(settings: settings),
            RouteFEngine(settings: settings)
        ]
    }

    // MARK: - Error Reporting

    private func scenePhaseLabel(for phase: ScenePhase) -> String {
        switch phase {
        case .active:
            "active"
        case .inactive:
            "inactive"
        case .background:
            "background"
        @unknown default:
            "unknown"
        }
    }

    private func diagnosticPayload(for window: FeatureWindow, final: Bool) -> [String: String] {
        [
            "windowId": "\(window.windowId)",
            "source": window.source.rawValue,
            "finalFlush": String(final),
            "durationSec": String(format: "%.1f", window.duration),
            "hasMotion": String(window.motion != nil),
            "hasAudio": String(window.audio != nil),
            "hasInteraction": String(window.interaction != nil),
            "hasWatch": String(window.watch != nil),
            "hasPhysiology": String(window.physiology != nil),
            "startTime": window.startTime.csvTimestamp,
            "endTime": window.endTime.csvTimestamp
        ]
    }

    private func postPredictionSnapshot() {
        guard !activePredictions.isEmpty else { return }
        let summary = activePredictions
            .map { prediction in
                let onset = prediction.predictedSleepOnset?.formattedTime ?? "nil"
                return "\(prediction.routeId.rawValue)=\(prediction.confidence.rawValue)/\(prediction.isAvailable ? "avail" : "unavail")@\(onset)"
            }
            .joined(separator: "; ")
        postDiagnosticEvent(
            "system.predictionSnapshot",
            payload: [
                "summary": summary
            ]
        )
    }

    private func postDiagnosticEvent(_ eventType: String, payload: [String: String] = [:]) {
        eventBus.post(
            RouteEvent(
                routeId: .A,
                eventType: eventType,
                payload: payload
            )
        )
    }

    private func reportError(title: String, message: String, severity: ErrorSeverity) async {
        let error = AppError(
            timestamp: Date(),
            title: title,
            message: message,
            severity: severity
        )
        lastError = error

        // Post to event bus for logging
        eventBus.post(RouteEvent(
            routeId: .A,
            eventType: "system.errorReported",
            payload: [
                "title": title,
                "message": message,
                "severity": severity.rawValue,
                "timestamp": ISO8601DateFormatter.cached.string(from: error.timestamp)
            ]
        ))
    }

    func clearLastError() {
        lastError = nil
    }

    private func makeReplayEngine(routeId: RouteId) -> RouteEngine? {
        switch routeId {
        case .C:
            RouteCEngine(settings: settings)
        case .D:
            RouteDEngine(settings: settings)
        default:
            nil
        }
    }

    private func replayMessage(
        routeId: RouteId,
        sessionDate: String,
        previousPrediction: RoutePrediction?,
        newPrediction: RoutePrediction
    ) -> String {
        guard
            let oldTime = previousPrediction?.predictedSleepOnset,
            let newTime = newPrediction.predictedSleepOnset
        else {
            return "Replayed Route \(routeId.rawValue) for \(sessionDate)"
        }

        let deltaMinutes = newTime.timeIntervalSince(oldTime) / 60
        if abs(deltaMinutes) < 0.5 {
            return "Replayed Route \(routeId.rawValue) for \(sessionDate) with no material change"
        }

        let direction = deltaMinutes > 0 ? "later" : "earlier"
        let deltaString = String(format: "%.1f", abs(deltaMinutes))
        return "Replayed Route \(routeId.rawValue) for \(sessionDate): \(deltaString) min \(direction)"
    }
}

#if DEBUG
extension AppModel {
    func debugPrepareWatchStartupTracking(for session: Session) {
        currentSession = session
        resetWatchStartupTracking()
        watchStartCommandIssuedAt = session.startTime
        hasIssuedWatchStartForCurrentSession = true
        lastIssuedWatchCommandKind = .startSession
    }

    func debugApplyWatchRuntimeSnapshot(_ snapshot: WatchRuntimeSnapshot, recordEvents: Bool = true) {
        applyWatchRuntimeSnapshot(snapshot, recordEvents: recordEvents)
    }

    func debugEvaluateWatchStartupTimeouts(now: Date, snapshot: WatchRuntimeSnapshot) {
        watchRuntimeSnapshot = snapshot
        syncWatchStartupFlags(with: snapshot)
        evaluateWatchStartupTimeouts(now: now, snapshot: snapshot)
        lastWatchRuntimeSnapshot = snapshot
    }

    func debugPreparePendingWatchSessionStart(for session: Session) {
        currentSession = session
        resetWatchStartupTracking()
        pendingWatchSessionStart = true
        isPreparingWatch = true
        hasIssuedWatchStartForCurrentSession = false
        lastIssuedWatchCommandKind = .prepareRuntime
    }

    func debugSetWatchSetupCompleted(_ completed: Bool) {
        watchSetupCompleted = completed
    }

    func debugBeginWatchRealtimeIfNeeded(for session: Session, recordEvents: Bool = true) {
        beginWatchRealtimeIfNeeded(for: session, recordEvents: recordEvents)
    }

    func debugWatchSetupCompletedState() -> Bool {
        watchSetupCompleted
    }

    func debugUpdatePredictionsForWatchAutoStop(_ predictions: [RoutePrediction], session: Session) {
        currentSession = session
        let previousRouteEPrediction = activePredictions.first { $0.routeId == .E }
        activePredictions = predictions
        syncWatchAutoStopState(previousRouteEPrediction: previousRouteEPrediction, sessionId: session.sessionId)
    }

    func debugIsWatchAutoStopScheduled() -> Bool {
        watchAutoStopTask != nil
    }

    func debugDidAutoStopWatchForCurrentSession() -> Bool {
        didAutoStopWatchForCurrentSession
    }
}
#endif
