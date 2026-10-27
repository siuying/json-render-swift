import Foundation

/// The plotted series of a `BarChart` or `LineChart`, shared by the SwiftUI and PDF renderers.
///
/// Built from the chart's resolved props: `data` (an array of objects, or an object whose
/// `data` member is one), `xKey`, `yKey` and an optional `aggregate`.
/// - Without `aggregate`, every record is one point in data order, labelled by its `xKey`
///   value. Records whose `yKey` is not a number (or numeric string) are skipped.
/// - With `aggregate`, records are grouped by `xKey` and the groups sorted by key: `"sum"` and
///   `"avg"` of `yKey` (non-numeric values count as 0) or `"count"` of records.
///
/// When the first record's `xKey` is an ISO date (`YYYY-MM-DD`, optionally followed by a
/// time), date values are labelled `"MMM dd"` (en-US, e.g. `"Mar 05"`) from the calendar day
/// as written, and aggregation groups them by that day.
public struct ChartData: Sendable, Hashable {
    public enum Aggregate: String, Sendable, Hashable, CaseIterable {
        case sum, count, avg
    }

    /// One bar or line point. `id` is its position, so repeated labels stay separate points.
    public struct Point: Sendable, Hashable, Identifiable {
        public let id: Int
        public let label: String
        public let value: Double

        public init(id: Int, label: String, value: Double) {
            self.id = id
            self.label = label
            self.value = value
        }
    }

    public let points: [Point]
    /// The plotted value's name: `yKey`, or `"count"` for `aggregate: "count"`.
    public let valueKey: String

    public var isEmpty: Bool { points.isEmpty }

    /// The plot height in points: the `height` prop (default 300), at least 200.
    public static func height(_ props: Props) -> Double {
        max(props.double("height") ?? 300, 200)
    }

    public init(points: [Point], valueKey: String) {
        self.points = points
        self.valueKey = valueKey
    }

    /// Reads `data`, `xKey`, `yKey` and `aggregate` from a chart's resolved props.
    public init(props: Props) {
        let data = Self(
            records: Self.records(from: props["data"]),
            xKey: props.string("xKey") ?? "",
            yKey: props.string("yKey") ?? "",
            aggregate: props.enum("aggregate"),
            labelKey: props.string("labelKey")
        )
        self.init(points: Self.capped(data.points, props: props), valueKey: data.valueKey)
    }

    public init(records: [JSONValue], xKey: String, yKey: String, aggregate: Aggregate?, labelKey: String? = nil) {
        guard let first = records.first else {
            self.init(points: [], valueKey: yKey)
            return
        }
        let dates = first[xKey]?.stringValue.flatMap(Self.isoDay) != nil

        guard let aggregate else {
            var points: [Point] = []
            for record in records {
                guard let value = Self.number(record[yKey]) else { continue }
                let x = record[xKey]
                let label = if let labelKey, let display = record[labelKey], display != .null {
                    JS.toString(display)
                } else if dates, let day = x?.stringValue.flatMap(Self.isoDay) {
                    Self.dayLabel(day)
                } else {
                    x.map { $0 == .null ? "" : JS.toString($0) } ?? ""
                }
                points.append(Point(id: points.count, label: label, value: value))
            }
            self.init(points: points, valueKey: yKey)
            return
        }

        var groups: [String: [JSONValue]] = [:]
        for record in records {
            let x = record[xKey]
            let key = if dates, let day = x?.stringValue.flatMap(Self.isoDay) {
                day.key
            } else if let x, x != .null {
                JS.toString(x)
            } else {
                "unknown"
            }
            groups[key, default: []].append(record)
        }
        let points = groups.keys.sorted(by: JS.lessThan).enumerated().map { index, key in
            let group = groups[key] ?? []
            let (total, scale) = Self.sum(group.map { Self.number($0[yKey]) ?? 0 })
            let value = switch aggregate {
            case .count: Double(group.count)
            case .sum: Self.clamped(total * scale)
            case .avg: Self.clamped(total / Double(group.count) * scale)
            }
            let label = labelKey.flatMap { group.first?[$0] }.flatMap { $0 == .null ? nil : JS.toString($0) }
                ?? (dates ? Self.isoDay(key).map(Self.dayLabel) ?? key : key)
            return Point(id: index, label: label, value: value)
        }
        self.init(points: points, valueKey: aggregate == .count ? "count" : yKey)
    }

    /// Caps displayed categories, preserving their order. The final slot sums the tail.
    static func capped(_ points: [Point], props: Props) -> [Point] {
        guard let raw = props.double("maxCategories"), raw.isFinite, raw >= 1,
              raw.rounded(.down) == raw, raw < Double(points.count) else { return points }
        let keep = Int(raw) - 1
        let (total, scale) = sum(points.dropFirst(keep).map(\.value))
        return Array(points.prefix(keep)) + [Point(id: keep, label: props.string("otherLabel") ?? "Other", value: clamped(total * scale))]
    }

    /// The chart's records: `data` itself when it is an array, else its `data` member.
    public static func records(from data: JSONValue?) -> [JSONValue] {
        data?.arrayValue ?? data?["data"]?.arrayValue ?? []
    }

    /// A finite number, or a string that starts with one (`parseFloat`), e.g. `"12.5"`.
    static func number(_ value: JSONValue?) -> Double? {
        let number: Double? = switch value {
        case .number(let number)?: number
        case .string(let string)?: JS.parseFloat(string)
        default: nil
        }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    /// `values` summed as `total × scale`. `scale` is 1 unless a partial sum overflows; then
    /// the values are summed divided by 2⁶⁴ (exact for such magnitudes), so cancellation
    /// such as `1.5e308 + 1.5e308 - 1.5e308` is kept whatever the order.
    static func sum(_ values: [Double]) -> (total: Double, scale: Double) {
        let plain = values.reduce(0, +)
        if plain.isFinite { return (plain, 1) }
        let scale = 0x1p64
        return (values.reduce(0) { $0 + $1 / scale }, scale)
    }

    /// Clamped to ±`Double.greatestFiniteMagnitude`.
    static func clamped(_ value: Double) -> Double {
        min(max(value, -.greatestFiniteMagnitude), .greatestFiniteMagnitude)
    }

    // MARK: Dates

    struct Day: Hashable {
        let year: Int
        let month: Int
        let day: Int
        var key: String { String(format: "%04d-%02d-%02d", year, month, day) }
    }

    /// The calendar day of `YYYY-MM-DD` or `YYYY-MM-DDT…`.
    static func isoDay(_ string: String) -> Day? {
        let utf8 = Array(string.utf8)
        guard utf8.count == 10 || (utf8.count > 10 && utf8[10] == UInt8(ascii: "T")) else { return nil }
        let text = String(decoding: utf8[..<10], as: UTF8.self)
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return Day(year: year, month: month, day: day)
    }

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `"MMM dd"` in en-US, e.g. `"Mar 05"`.
    static func dayLabel(_ day: Day) -> String {
        "\(monthNames[day.month - 1]) \(String(format: "%02d", day.day))"
    }
}
