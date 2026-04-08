import Foundation

extension ISO8601DateFormatter {
    static var cached: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

extension Date {
    var formattedTime: String {
        DateFormatter.shortTime.string(from: self)
    }

    var formattedDateTime: String {
        DateFormatter.longDateTime.string(from: self)
    }

    var csvTimestamp: String {
        ISO8601DateFormatter.cached.string(from: self)
    }
}

extension DateFormatter {
    static var shortTime: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }

    static var longDateTime: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
}

extension Array where Element == Double {
    var median: Double? {
        guard !isEmpty else { return nil }
        let sorted = self.sorted()
        if sorted.count.isMultiple(of: 2) {
            let upper = sorted[sorted.count / 2]
            let lower = sorted[sorted.count / 2 - 1]
            return (upper + lower) / 2
        }
        return sorted[sorted.count / 2]
    }
}

extension Double {
    var formatted3: String {
        String(format: "%.3f", self)
    }
}
