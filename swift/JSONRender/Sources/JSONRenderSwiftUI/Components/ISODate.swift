import Foundation

/// ISO-8601 conversions for `DatePicker`: `YYYY-MM-DD` (calendar date, local time zone)
/// for date-only pickers, full internet date-time strings otherwise.
enum ISODate {
    /// Parses `YYYY-MM-DD`, `YYYY-MM-DDTHH:mm[:ss][.SSS][Z|±hh:mm]`; a date-time without a
    /// zone is read in the local time zone.
    static func parse(_ string: String, calendar: Calendar = .current) -> Date? {
        let text = string.trimmingCharacters(in: .whitespaces)
        if let date = parseCalendarDate(text, calendar: calendar) { return date }
        for style in [Date.ISO8601FormatStyle(includingFractionalSeconds: true), Date.ISO8601FormatStyle()] {
            if let date = try? style.parse(text) { return date }
        }
        return parseLocalDateTime(text, calendar: calendar)
    }

    /// `YYYY-MM-DD` in `calendar`'s time zone.
    static func formatDate(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
    }

    /// Internet date-time in UTC, e.g. `2025-06-01T18:30:00Z`.
    static func formatDateTime(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }

    private static func parseCalendarDate(_ text: String, calendar: Calendar) -> Date? {
        guard let (year, month, day) = calendarDateParts(text) else { return nil }
        return validatedDate(DateComponents(year: year, month: month, day: day), calendar: calendar)
    }

    private static func calendarDateParts(_ text: some StringProtocol) -> (Int, Int, Int)? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return (year, month, day)
    }

    /// `YYYY-MM-DDTHH:mm[:ss[.fff]]` read as wall-clock time in `calendar`'s time zone.
    /// Built from date components (not midnight + duration) so DST days keep the written
    /// time. Nonexistent times (spring-forward gap) resolve to the next valid time and
    /// ambiguous ones (fall-back) to the first occurrence, per `Calendar.date(from:)`.
    private static func parseLocalDateTime(_ text: String, calendar: Calendar) -> Date? {
        let halves = text.split(separator: "T", maxSplits: 1)
        guard halves.count == 2, let (year, month, day) = calendarDateParts(halves[0]) else { return nil }
        let time = halves[1].split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(time.count), time[0].count == 2, time[1].count == 2,
              let hour = Int(time[0]), let minute = Int(time[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var second = 0
        var nanosecond = 0
        if time.count == 3 {
            let secondParts = time[2].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            guard secondParts[0].count == 2, let whole = Int(secondParts[0]), (0...59).contains(whole) else { return nil }
            second = whole
            if secondParts.count == 2 {
                let fraction = secondParts[1]
                guard !fraction.isEmpty, fraction.allSatisfy(\.isNumber), let digits = Double("0." + fraction) else { return nil }
                nanosecond = Int((digits * 1_000_000_000).rounded())
            }
        }
        let components = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second, nanosecond: nanosecond
        )
        return validatedDate(components, calendar: calendar)
    }

    /// Rejects impossible calendar dates (e.g. 2025-02-31) that `Calendar` would roll over.
    private static func validatedDate(_ components: DateComponents, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == components.year, resolved.month == components.month, resolved.day == components.day
        else { return nil }
        return date
    }
}
