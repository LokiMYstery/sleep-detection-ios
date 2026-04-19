import Foundation

protocol SessionRepository: Sendable {
    func createSession(_ session: Session) async throws
    func updateSession(_ session: Session) async throws
    func appendWindow(_ window: FeatureWindow, to sessionId: UUID) async throws
    func appendEvent(_ event: RouteEvent, to sessionId: UUID) async throws
    func savePredictions(_ predictions: [RoutePrediction], for sessionId: UUID) async throws
    func saveTimeline(_ timeline: SleepTimeline, for sessionId: UUID) async throws
    func saveUnifiedArtifacts(_ artifacts: UnifiedSessionArtifacts, for sessionId: UUID) async throws
    func saveTruth(_ truth: TruthRecord, for sessionId: UUID) async throws
    func loadBundles() async throws -> [SessionBundle]
    func loadBundle(sessionId: UUID) async throws -> SessionBundle?
    func loadWindows(sessionId: UUID) async throws -> [FeatureWindow]
    func recoverInterruptedSessions(now: Date) async throws -> [Session]
}

actor FileSessionRepository: SessionRepository {
    private let fileManager: FileManager
    private let baseURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.baseURL = documents
            .appendingPathComponent("SleepPOC", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    init(baseURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.baseURL = baseURL
    }

    func createSession(_ session: Session) async throws {
        try ensureBaseDirectory()
        try ensureSessionDirectory(session.sessionId)
        try writeJSON(session, to: sessionURL(for: session.sessionId, fileName: "session.json"))
    }

    func updateSession(_ session: Session) async throws {
        try ensureSessionDirectory(session.sessionId)
        try writeJSON(session, to: sessionURL(for: session.sessionId, fileName: "session.json"))
    }

    func appendWindow(_ window: FeatureWindow, to sessionId: UUID) async throws {
        try ensureSessionDirectory(sessionId)
        try appendJSONLine(window, to: sessionURL(for: sessionId, fileName: "windows.jsonl"))
    }

    func appendEvent(_ event: RouteEvent, to sessionId: UUID) async throws {
        try ensureSessionDirectory(sessionId)
        try appendJSONLine(event, to: sessionURL(for: sessionId, fileName: "events.jsonl"))
    }

    func savePredictions(_ predictions: [RoutePrediction], for sessionId: UUID) async throws {
        try ensureSessionDirectory(sessionId)
        try writeJSON(
            StoredPredictions(predictions: predictions),
            to: sessionURL(for: sessionId, fileName: "predictions.json")
        )
    }

    func saveTimeline(_ timeline: SleepTimeline, for sessionId: UUID) async throws {
        try ensureSessionDirectory(sessionId)
        try writeJSON(
            timeline,
            to: sessionURL(for: sessionId, fileName: "timeline.json")
        )
    }

    func saveUnifiedArtifacts(_ artifacts: UnifiedSessionArtifacts, for sessionId: UUID) async throws {
        try ensureSessionDirectory(sessionId)
        try writeJSON(
            artifacts,
            to: sessionURL(for: sessionId, fileName: "unified.json")
        )
    }

    func saveTruth(_ truth: TruthRecord, for sessionId: UUID) async throws {
        try ensureSessionDirectory(sessionId)
        try writeJSON(truth, to: sessionURL(for: sessionId, fileName: "truth.json"))
    }

    func loadBundles() async throws -> [SessionBundle] {
        guard fileManager.fileExists(atPath: baseURL.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try directories.compactMap { directory in
            let sessionURL = directory.appendingPathComponent("session.json")
            guard fileManager.fileExists(atPath: sessionURL.path) else { return nil }
            let session: Session = try readJSON(Session.self, from: sessionURL)
            let windows = try readJSONLines(FeatureWindow.self, from: directory.appendingPathComponent("windows.jsonl"))
            let events = try readJSONLines(RouteEvent.self, from: directory.appendingPathComponent("events.jsonl"))
            let predictions = try readPredictions(from: directory.appendingPathComponent("predictions.json"))
            let truth = normalizeTruth(
                try readTruth(from: directory.appendingPathComponent("truth.json")),
                for: session
            )
            let timeline = try readTimeline(from: directory.appendingPathComponent("timeline.json"))
            let unifiedArtifacts = try readUnifiedArtifacts(from: directory.appendingPathComponent("unified.json"))
            return SessionBundle(
                session: session,
                windows: windows,
                events: events,
                predictions: predictions,
                truth: truth,
                timeline: timeline,
                unifiedArtifacts: unifiedArtifacts
            )
        }
        .sorted { $0.session.startTime > $1.session.startTime }
    }

    func loadBundle(sessionId: UUID) async throws -> SessionBundle? {
        let directory = sessionDirectory(for: sessionId)
        let sessionURL = directory.appendingPathComponent("session.json")
        guard fileManager.fileExists(atPath: sessionURL.path) else { return nil }
        let session: Session = try readJSON(Session.self, from: sessionURL)
        let windows = try readJSONLines(FeatureWindow.self, from: directory.appendingPathComponent("windows.jsonl"))
        let events = try readJSONLines(RouteEvent.self, from: directory.appendingPathComponent("events.jsonl"))
        let predictions = try readPredictions(from: directory.appendingPathComponent("predictions.json"))
        let truth = normalizeTruth(
            try readTruth(from: directory.appendingPathComponent("truth.json")),
            for: session
        )
        let timeline = try readTimeline(from: directory.appendingPathComponent("timeline.json"))
        let unifiedArtifacts = try readUnifiedArtifacts(from: directory.appendingPathComponent("unified.json"))
        return SessionBundle(
            session: session,
            windows: windows,
            events: events,
            predictions: predictions,
            truth: truth,
            timeline: timeline,
            unifiedArtifacts: unifiedArtifacts
        )
    }

    func loadWindows(sessionId: UUID) async throws -> [FeatureWindow] {
        try readJSONLines(
            FeatureWindow.self,
            from: sessionURL(for: sessionId, fileName: "windows.jsonl")
        )
    }

    func recoverInterruptedSessions(now: Date = Date()) async throws -> [Session] {
        let bundles = try await loadBundles()
        var recovered: [Session] = []
        for bundle in bundles where bundle.session.status == .recording && bundle.session.endTime == nil {
            var session = bundle.session
            session.status = .pendingTruth
            session.interrupted = true
            session.dataCompleteness = "partial"
            session.interruptedAt = bundle.windows.last?.endTime ?? bundle.events.last?.timestamp ?? now
            try await updateSession(session)
            recovered.append(session)
        }
        return recovered
    }

    private func readPredictions(from url: URL) throws -> [RoutePrediction] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let stored: StoredPredictions = try readJSON(StoredPredictions.self, from: url)
        return stored.predictions
    }

    private func readTruth(from url: URL) throws -> TruthRecord? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try readJSON(TruthRecord.self, from: url)
    }

    private func normalizeTruth(_ truth: TruthRecord?, for session: Session) -> TruthRecord? {
        guard var truth else { return nil }
        if truth.effectiveResolution != nil {
            return truth
        }
        if truth.hasTruth, truth.healthKitSleepOnset != nil {
            truth.resolution = .resolvedOnset
            return truth
        }
        guard truth.hasTruth == false else { return truth }
        switch session.status {
        case .labeled, .archived:
            truth.resolution = .noQualifyingSleep
            truth.healthKitSleepOnset = nil
            truth.errors = [:]
            return truth
        case .created, .recording, .pendingTruth, .interrupted:
            return nil
        }
    }

    private func readTimeline(from url: URL) throws -> SleepTimeline? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try readJSON(SleepTimeline.self, from: url)
    }

    private func readUnifiedArtifacts(from url: URL) throws -> UnifiedSessionArtifacts? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try readJSON(UnifiedSessionArtifacts.self, from: url)
    }

    private func ensureBaseDirectory() throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    private func ensureSessionDirectory(_ sessionId: UUID) throws {
        try ensureBaseDirectory()
        try fileManager.createDirectory(at: sessionDirectory(for: sessionId), withIntermediateDirectories: true)
    }

    private func sessionDirectory(for sessionId: UUID) -> URL {
        baseURL.appendingPathComponent(sessionId.uuidString, isDirectory: true)
    }

    private func sessionURL(for sessionId: UUID, fileName: String) -> URL {
        sessionDirectory(for: sessionId).appendingPathComponent(fileName)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder.pretty.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func appendJSONLine<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder.jsonLines.encode(value)
        let line = data + Data([0x0A])
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: line)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder.iso8601.decode(type, from: data)
    }

    private func readJSONLines<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard let string = String(data: data, encoding: .utf8) else { return [] }
        return string
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let lineData = line.data(using: .utf8) else { return nil }
                return try? JSONDecoder.iso8601.decode(T.self, from: lineData)
            }
    }
}
