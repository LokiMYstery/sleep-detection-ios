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

    func percentile(_ fraction: Double) -> Double? {
        guard !isEmpty else { return nil }
        let clamped: Double = Swift.min(Swift.max(fraction, 0.0), 1.0)
        let sorted = self.sorted()
        let position = Double(sorted.count - 1) * clamped
        let lowerIndex = Int(position.rounded(FloatingPointRoundingRule.down))
        let upperIndex = Int(position.rounded(FloatingPointRoundingRule.up))
        if lowerIndex == upperIndex {
            return sorted[lowerIndex]
        }
        let lowerValue: Double = sorted[lowerIndex]
        let upperValue: Double = sorted[upperIndex]
        let weight: Double = position - Double(lowerIndex)
        return lowerValue + ((upperValue - lowerValue) * weight)
    }
}

extension Double {
    var formatted2: String {
        String(format: "%.2f", self)
    }

    var formatted3: String {
        String(format: "%.3f", self)
    }
}
