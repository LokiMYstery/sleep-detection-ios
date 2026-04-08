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

    private var routeRunner: RouteRunner?
    private var recordingTask: Task<Void, Never>?
    private var watchPollingTask: Task<Void, Never>?
    private var eventSubscriptionID: UUID?
    private var nextWindowId = 0
    private var lastWindowBoundary: Date?
    private var lastWatchReachable: Bool?
    private var hasBootstrapped = false

    init(
        repository: SessionRepository = FileSessionRepository(),
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        healthKitService: LiveHealthKitService = LiveHealthKitService(),
        motionProvider: LiveMotionProvider = LiveMotionProvider(),
        interactionProvider: LiveInteractionProvider = LiveInteractionProvider(),
        audioProvider: AudioProvider = LiveAudioProvider(),
        watchProvider: WatchProvider = LiveWatchProvider()
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
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        settings = await settingsStore.load()
        _ = await healthKitService.requestAuthorization()
        _ = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        deviceCondition = await healthKitService.detectDeviceCondition()

        let sleepSamples = settings.disableHealthKitPriors ? [] : await healthKitService.fetchRecentSleepSamples()
        let heartRateSamples = settings.disableHealthKitPriors ? [] : await healthKitService.fetchRecentHeartRateSamples()
        priorSnapshot = PriorComputer.compute(
            sleepSamples: sleepSamples,
            heartRateSamples: heartRateSamples,
            settings: settings,
            hasHealthKitAccess: deviceCondition.hasHealthKitAccess && !settings.disableHealthKitPriors
        )

        _ = try? await repository.recoverInterruptedSessions(now: Date())
        try? await truthRefillService.refillPendingTruths()
        await reloadBundles()
    }

    func handleScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .active:
            deviceCondition = await healthKitService.detectDeviceCondition()
            try? await truthRefillService.refillPendingTruths()
            await reloadBundles()
        default:
            break
        }
    }

    func markInteraction() {
        interactionProvider.markInteraction()
    }

    func startSession() async {
        guard currentSession == nil else { return }
        await bootstrapIfNeeded()
        deviceCondition = await healthKitService.detectDeviceCondition()

        let start = Date()
        var session = Session.make(
            startTime: start,
            deviceCondition: deviceCondition,
            priorLevel: priorSnapshot.level,
            enabledRoutes: RouteId.allCases,
            disabledFeatures: settings.disableHealthKitPriors ? ["healthkitPriors"] : []
        )
        session.status = .recording
        session.phonePlacement = settings.defaultPhonePlacement.rawValue

        do {
            try await repository.createSession(session)
            try interactionProvider.start(session: session)
            try motionProvider.start(session: session)
            try audioProvider.start(session: session)
            try watchProvider.start(session: session)
        } catch {
            return
        }

        currentSession = session
        recentWindows = []
        nextWindowId = 0
        lastWindowBoundary = start
        lastWatchReachable = deviceCondition.watchReachable
        eventBus.reset()
        updateWatchConnectivityState()

        let runner = RouteRunner(engines: makeRouteEngines())
        routeRunner = runner
        runner.start(session: session, priors: priorSnapshot.routePriors)
        activePredictions = runner.currentPredictions()
        try? await repository.savePredictions(activePredictions, for: session.sessionId)

        eventSubscriptionID = eventBus.subscribe { [weak self] event in
            guard let self, let sessionId = self.currentSession?.sessionId else { return }
            Task {
                try? await self.repository.appendEvent(event, to: sessionId)
            }
        }

        recordingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self.flushCurrentWindow(final: false)
            }
        }

        watchPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await self.flushPendingWatchWindows()
            }
        }
    }

    func stopSession() async {
        guard var session = currentSession else { return }

        recordingTask?.cancel()
        recordingTask = nil
        watchPollingTask?.cancel()
        watchPollingTask = nil

        await flushPendingWatchWindows()
        await flushCurrentWindow(final: true)

        motionProvider.stop()
        interactionProvider.stop()
        audioProvider.stop()
        watchProvider.stop()

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
        let sleepSamples = settings.disableHealthKitPriors ? [] : await healthKitService.fetchRecentSleepSamples()
        let heartRateSamples = settings.disableHealthKitPriors ? [] : await healthKitService.fetchRecentHeartRateSamples()
        priorSnapshot = PriorComputer.compute(
            sleepSamples: sleepSamples,
            heartRateSamples: heartRateSamples,
            settings: settings,
            hasHealthKitAccess: deviceCondition.hasHealthKitAccess && !settings.disableHealthKitPriors
        )
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

    private func flushCurrentWindow(final: Bool) async {
        guard let session = currentSession else { return }
        let end = Date()
        let start = lastWindowBoundary ?? session.startTime
        guard end > start else { return }

        let duration = end.timeIntervalSince(start)
        let motion = motionProvider.drainMotionFeatures(windowDuration: duration)
        let audio = audioProvider.consumeWindow(windowDuration: duration)
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
            updateWatchConnectivityState()
            return
        }

        for window in watchWindows {
            await processWindow(window, sessionId: sessionId)
        }
        updateWatchConnectivityState()
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
        recentWindows = Array(([window] + recentWindows).prefix(20))
        try? await repository.appendWindow(window, to: sessionId)
        routeRunner?.process(window: window)
        activePredictions = routeRunner?.currentPredictions() ?? activePredictions
        try? await repository.savePredictions(activePredictions, for: sessionId)
    }

    private func updateWatchConnectivityState() {
        let connectivity = watchProvider.connectivitySnapshot()
        if let previous = lastWatchReachable, previous != connectivity.isReachable {
            eventBus.post(
                RouteEvent(
                    routeId: .E,
                    eventType: connectivity.isReachable ? "custom.watchConnected" : "custom.watchDisconnected",
                    payload: [
                        "watchReachable": String(connectivity.isReachable),
                        "dataQuality": connectivity.isReachable ? "good" : "partial"
                    ]
                )
            )
        }
        lastWatchReachable = connectivity.isReachable
        deviceCondition.hasWatch = connectivity.isPaired
        deviceCondition.watchReachable = connectivity.isReachable
    }

    private func makeRouteEngines() -> [RouteEngine] {
        [
            RouteAEngine(settings: settings),
            RouteBEngine(settings: settings),
            RouteCEngine(settings: settings),
            RouteDEngine(settings: settings),
            RouteEEngine(settings: settings)
        ]
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
