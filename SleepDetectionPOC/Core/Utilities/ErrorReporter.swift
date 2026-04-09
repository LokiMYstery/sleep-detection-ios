import Foundation

/// Severity level for reported errors
enum ErrorSeverity: String, Codable, Sendable {
    case warning    // Non-critical, operation can continue
    case error      // Operation failed but app can continue
    case critical   // App may be in an inconsistent state
}

/// A reported error with context for debugging
struct ReportedError: Identifiable, Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let severity: ErrorSeverity
    let domain: String
    let code: String
    let message: String
    let file: String
    let function: String
    let line: Int
    let underlyingError: String?
    let context: [String: String]
}

/// Protocol for error reporting
@MainActor
protocol ErrorReporter: Sendable {
    func report(
        severity: ErrorSeverity,
        domain: String,
        code: String,
        message: String,
        file: String,
        function: String,
        line: Int,
        underlyingError: Error?,
        context: [String: String]
    )
}

// MARK: - Default Implementation

extension ErrorReporter {
    func report(
        severity: ErrorSeverity,
        domain: String,
        code: String,
        message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        underlyingError: Error? = nil,
        context: [String: String] = [:]
    ) {
        report(
            severity: severity,
            domain: domain,
            code: code,
            message: message,
            file: (file as NSString).lastPathComponent,
            function: function,
            line: line,
            underlyingError: underlyingError,
            context: context
        )
    }
}

// MARK: - Convenience Methods

extension ErrorReporter {
    func logWarning(
        domain: String,
        code: String,
        message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        context: [String: String] = [:]
    ) {
        report(
            severity: .warning,
            domain: domain,
            code: code,
            message: message,
            file: file,
            function: function,
            line: line,
            underlyingError: nil,
            context: context
        )
    }

    func logError(
        domain: String,
        code: String,
        message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        underlyingError: Error? = nil,
        context: [String: String] = [:]
    ) {
        report(
            severity: .error,
            domain: domain,
            code: code,
            message: message,
            file: file,
            function: function,
            line: line,
            underlyingError: underlyingError,
            context: context
        )
    }

    func logCritical(
        domain: String,
        code: String,
        message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        underlyingError: Error? = nil,
        context: [String: String] = [:]
    ) {
        report(
            severity: .critical,
            domain: domain,
            code: code,
            message: message,
            file: file,
            function: function,
            line: line,
            underlyingError: underlyingError,
            context: context
        )
    }
}

// MARK: - Event Bus Error Reporter

@MainActor
final class EventBusErrorReporter: ErrorReporter, @unchecked Sendable {
    private let eventBus: EventBus
    private let sessionProvider: () -> Session?

    init(eventBus: EventBus = .shared, sessionProvider: @escaping () -> Session? = { nil }) {
        self.eventBus = eventBus
        self.sessionProvider = sessionProvider
    }

    func report(
        severity: ErrorSeverity,
        domain: String,
        code: String,
        message: String,
        file: String,
        function: String,
        line: Int,
        underlyingError: Error?,
        context: [String: String]
    ) {
        var payload: [String: String] = [
            "severity": severity.rawValue,
            "domain": domain,
            "code": code,
            "message": message,
            "file": file,
            "function": function,
            "line": String(line),
            "timestamp": ISO8601DateFormatter.cached.string(from: Date())
        ]

        if let underlyingError {
            payload["underlyingError"] = String(describing: underlyingError)
        }

        for (key, value) in context {
            payload["context.\(key)"] = value
        }

        let event = RouteEvent(
            routeId: .A, // System events use Route A as default
            eventType: "system.error.\(severity.rawValue)",
            payload: payload
        )

        eventBus.post(event)
    }
}
