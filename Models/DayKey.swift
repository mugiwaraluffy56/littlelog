import Foundation

/// A stable identifier for a local calendar day, formatted `yyyy-MM-dd`.
nonisolated enum DayKey {
    static func make(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    /// Resolves "today", "tomorrow", "yesterday" or a real `YYYY-MM-DD` date to a day key.
    /// Returns `nil` for anything else, including impossible dates like 2026-02-30.
    static func resolve(_ input: String?, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String? {
        let text = (input ?? "today").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let offset: Int? = switch text {
        case "", "today": 0
        case "tomorrow": 1
        case "yesterday": -1
        default: nil
        }
        if let offset {
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
            return make(for: date, calendar: calendar)
        }
        return date(for: text, calendar: calendar).map { make(for: $0, calendar: calendar) }
    }

    /// Noon of the key's day, a safe representative instant for formatting.
    static func date(for key: String, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: components),
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day
        else { return nil }
        return date
    }
}
