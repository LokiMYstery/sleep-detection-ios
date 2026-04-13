import Foundation
import Testing
@testable import SleepDetectionPOC

@Suite("Watch Auto Stop")
struct WatchAutoStopTests {
    @Test("AppModel auto-stops watch collection after Route E confirmation delay")
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

        model.debugUpdatePredictionsForWatchAutoStop(
            [
                RoutePrediction(
                    routeId: .E,
                    predictedSleepOnset: start.addingTimeInterval(120),
                    confidence: .confirmed,
                    evidenceSummary: "Watch fusion confirmed",
                    lastUpdated: start.addingTimeInterval(120),
                    isAvailable: true
                )
            ],
            session: session
        )

        #expect(model.debugIsWatchAutoStopScheduled())
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(watchProvider.stopCallCount == 1)
        #expect(model.debugDidAutoStopWatchForCurrentSession())
    }

    @Test("AppModel cancels watch auto-stop if Route E loses confirmation before deadline")
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

        model.debugUpdatePredictionsForWatchAutoStop(
            [
                RoutePrediction(
                    routeId: .E,
                    predictedSleepOnset: start.addingTimeInterval(120),
                    confidence: .confirmed,
                    evidenceSummary: "Watch fusion confirmed",
                    lastUpdated: start.addingTimeInterval(120),
                    isAvailable: true
                )
            ],
            session: session
        )

        #expect(model.debugIsWatchAutoStopScheduled())

        model.debugUpdatePredictionsForWatchAutoStop(
            [
                RoutePrediction(
                    routeId: .E,
                    predictedSleepOnset: nil,
                    confidence: .none,
                    evidenceSummary: "Monitoring Watch motion + heart rate + iPhone interaction",
                    lastUpdated: start.addingTimeInterval(150),
                    isAvailable: true
                )
            ],
            session: session
        )

        #expect(!model.debugIsWatchAutoStopScheduled())
        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(watchProvider.stopCallCount == 0)
        #expect(!model.debugDidAutoStopWatchForCurrentSession())
    }
}

private final class AutoStopRecordingWatchProvider: WatchProvider, @unchecked Sendable {
    let providerId = "watch.auto-stop.test"

    private(set) var stopCallCount = 0

    func start(session: Session) throws {}
    func prepareRuntime(sessionId: UUID) throws {}

    func stop() {
        stopCallCount += 1
    }

    func currentWindow() -> SensorWindowSnapshot? { nil }
    func drainPendingWindows() -> [FeatureWindow] { [] }
    func runtimeSnapshot() -> WatchRuntimeSnapshot { .unavailable }
    func drainDiagnostics() -> [WatchProviderDiagnostic] { [] }
}
