import Foundation
import Testing
@testable import SleepDetectionPOC

@Suite("Watch Auto Stop")
struct WatchAutoStopTests {
    @Test("AppModel auto-stops watch collection after unified confirmation delay")
    @MainActor
    func appModelAutoStopsWatchCollectionAfterConfirmation() async throws {
        let watchProvider = AutoStopRecordingWatchProvider()
        let model = AppModel(
            watchProvider: watchProvider,
            watchAutoStopDelaySeconds: 0.01
        )
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: true, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )

        model.debugUpdateUnifiedDecisionForWatchAutoStop(
            UnifiedSleepDecision(
                state: .confirmed,
                capabilityProfile: UnifiedCapabilityProfile(channels: [.watchMotion, .watchHeartRate, .phoneMotion, .phoneInteraction]),
                episodeStartAt: start.addingTimeInterval(60),
                candidateAt: start.addingTimeInterval(90),
                confirmedAt: start.addingTimeInterval(120),
                progressScore: 3.2,
                candidateThreshold: 1.5,
                confirmThreshold: 3,
                evidenceSummary: "Unified chain confirmed sleep",
                denialSummary: nil,
                isFinal: true,
                lastUpdated: start.addingTimeInterval(120)
            ),
            session: session
        )

        #expect(model.debugIsWatchAutoStopScheduled())
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(watchProvider.stopCallCount == 1)
        #expect(model.debugDidAutoStopWatchForCurrentSession())
    }

    @Test("AppModel cancels watch auto-stop if unified confirmation is lost before deadline")
    @MainActor
    func appModelCancelsWatchAutoStopWhenConfirmationIsLost() async throws {
        let watchProvider = AutoStopRecordingWatchProvider()
        let model = AppModel(
            watchProvider: watchProvider,
            watchAutoStopDelaySeconds: 0.05
        )
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: true, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )

        model.debugUpdateUnifiedDecisionForWatchAutoStop(
            UnifiedSleepDecision(
                state: .confirmed,
                capabilityProfile: UnifiedCapabilityProfile(channels: [.watchMotion, .watchHeartRate]),
                episodeStartAt: start.addingTimeInterval(60),
                candidateAt: start.addingTimeInterval(90),
                confirmedAt: start.addingTimeInterval(120),
                progressScore: 3.1,
                candidateThreshold: 1.5,
                confirmThreshold: 3,
                evidenceSummary: "Unified chain confirmed sleep",
                denialSummary: nil,
                isFinal: true,
                lastUpdated: start.addingTimeInterval(120)
            ),
            session: session
        )

        #expect(model.debugIsWatchAutoStopScheduled())

        model.debugUpdateUnifiedDecisionForWatchAutoStop(
            UnifiedSleepDecision(
                state: .monitoring,
                capabilityProfile: UnifiedCapabilityProfile(channels: [.watchMotion, .watchHeartRate]),
                episodeStartAt: nil,
                candidateAt: nil,
                confirmedAt: nil,
                progressScore: 0.4,
                candidateThreshold: 1.5,
                confirmThreshold: 3,
                evidenceSummary: "Monitoring unified evidence",
                denialSummary: nil,
                isFinal: false,
                lastUpdated: start.addingTimeInterval(150)
            ),
            session: session
        )

        #expect(!model.debugIsWatchAutoStopScheduled())
        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(watchProvider.stopCallCount == 0)
        #expect(!model.debugDidAutoStopWatchForCurrentSession())
    }

    @Test("AppModel does not schedule watch auto-stop for phone-only unified confirmations")
    @MainActor
    func appModelDoesNotScheduleWatchAutoStopForPhoneOnlySession() async throws {
        let watchProvider = AutoStopRecordingWatchProvider()
        let model = AppModel(
            watchProvider: watchProvider,
            watchAutoStopDelaySeconds: 0.01
        )
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )

        model.debugUpdateUnifiedDecisionForWatchAutoStop(
            UnifiedSleepDecision(
                state: .confirmed,
                capabilityProfile: UnifiedCapabilityProfile(channels: [.phoneMotion, .phoneInteraction]),
                episodeStartAt: start.addingTimeInterval(60),
                candidateAt: start.addingTimeInterval(90),
                confirmedAt: start.addingTimeInterval(120),
                progressScore: 3.0,
                candidateThreshold: 1.5,
                confirmThreshold: 3.0,
                evidenceSummary: "Phone-only unified confirmation",
                denialSummary: nil,
                isFinal: true,
                lastUpdated: start.addingTimeInterval(120)
            ),
            session: session
        )

        #expect(!model.debugIsWatchAutoStopScheduled())
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(watchProvider.stopCallCount == 0)
        #expect(!model.debugDidAutoStopWatchForCurrentSession())
    }
}

private final class AutoStopRecordingWatchProvider: WatchProvider, @unchecked Sendable {
    let providerId = "watch.auto-stop.test"

    private(set) var stopCallCount = 0

    func start(session: Session) throws {}
    func prepareRuntime(sessionId: UUID) throws {}
    func refreshDesiredRuntimeLease() {}

    func stop() {
        stopCallCount += 1
    }

    func currentWindow() -> SensorWindowSnapshot? { nil }
    func drainPendingWindows() -> [FeatureWindow] { [] }
    func runtimeSnapshot() -> WatchRuntimeSnapshot { .unavailable }
    func drainDiagnostics() -> [WatchProviderDiagnostic] { [] }
}
