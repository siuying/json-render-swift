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
        public internal(set) var id: Int
        public let label: String
        public let value: Double
        public let records: [JSONValue]
        public let isMissing: Bool
        public internal(set) var isOther: Bool
        var includesOtherFlag = false
        var includesDisplay = false
        public internal(set) var formattedValue: String?

        public var valueText: String {
            if includesDisplay, let formattedValue { return formattedValue }
            return isMissing ? String(localized: "n/a") : formattedValue ?? value.formatted()
        }

        func reindexed(_ index: Int, formattedValue: String? = nil) -> Point {
            var point = self
            point.id = index
            point.formattedValue = formattedValue ?? self.formattedValue
            return point
        }

        /// A renderer-independent press payload. Source fields remain in `records`.
        public var datum: JSONValue {
            var payload: [String: JSONValue] = ["index": .number(Double(id)), "label": .string(label), "value": isMissing ? .null : .number(value), "records": .array(records)]
            if includesOtherFlag { payload["isOther"] = .bool(isOther) }
            if includesDisplay { payload["display"] = .string(valueText) }
            return .object(payload)
        }

        public init(id: Int, label: String, value: Double, records: [JSONValue] = [], isMissing: Bool = false, isOther: Bool = false, formattedValue: String? = nil) {
            self.id = id
            self.label = label
            self.value = value
            self.records = records
            self.isMissing = isMissing
            self.isOther = isOther
            self.formattedValue = formattedValue
        }
    }

    public let points: [Point]
    /// The plotted value's name: `yKey`, or `"count"` for `aggregate: "count"`.
    public let valueKey: String

    public var isEmpty: Bool { points.isEmpty }

    /// The plot height in points: the `height` prop (default 300), at least 200.
    public static func height(_ props: Props, categoryCount: Int? = nil) -> Double {
        if props.bool("horizontal") == true, props.double("height") == nil {
            return max(200, Double(categoryCount ?? ChartData(props: props).points.count) * 34 + 32)
        }
        return max(props.double("height") ?? 300, 200)
    }

    /// Independent line/area runs prevent an unknown value from becoming a zero-valued sample.
    public var numericSegments: [[Point]] {
        var result: [[Point]] = []
        var segment: [Point] = []
        for point in points {
            if point.isMissing {
                if !segment.isEmpty { result.append(segment); segment = [] }
            } else { segment.append(point) }
        }
        if !segment.isEmpty { result.append(segment) }
        return result
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
            labelKey: props.string("labelKey"),
            missing: props.string("missing") == "show"
        )
        let identified = data.points.map { source in
            var point = source
            if let key = props.string("otherKey") {
                point.isOther = point.records.contains { JS.isTruthy($0[key]) }
                point.includesOtherFlag = true
            }
            return point
        }
        let points = Self.capped(identified, props: props).map { point in
            var point = point
            point.includesDisplay = props.string("displayKey") != nil
            point.formattedValue = Self.sourceDisplay(point.records, props: props)
                ?? (point.includesDisplay && point.isMissing ? nil : ChartValueFormatting.string(point.value, props: props))
                ?? (point.includesDisplay && !point.isMissing ? point.value.formatted() : nil)
            return point
        }
        self.init(points: points, valueKey: data.valueKey)
    }

    public init(records: [JSONValue], xKey: String, yKey: String, aggregate: Aggregate?, labelKey: String? = nil, missing: Bool = false) {
        guard let first = records.first else {
            self.init(points: [], valueKey: yKey)
            return
        }
        let dates = first[xKey]?.stringValue.flatMap(Self.isoDay) != nil

        guard let aggregate else {
            var points: [Point] = []
            for record in records {
                let number = Self.number(record[yKey])
                guard number != nil || missing else { continue }
                let value = number ?? 0
                let x = record[xKey]
                let label = if let labelKey, let display = record[labelKey], display != .null {
                    JS.toString(display)
                } else if dates, let day = x?.stringValue.flatMap(Self.isoDay) {
                    Self.dayLabel(day)
                } else {
                    x.map { $0 == .null ? "" : JS.toString($0) } ?? ""
                }
                points.append(Point(id: points.count, label: label, value: value, records: [record], isMissing: number == nil))
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
            return Point(id: index, label: label, value: value, records: group, isMissing: missing && aggregate != .count && group.allSatisfy { Self.number($0[yKey]) == nil })
        }
        self.init(points: points, valueKey: aggregate == .count ? "count" : yKey)
    }

    /// Keep the largest values, resolving ties by existing order. Survivors retain
    /// their display order; the final Other slot merges explicit Other entries and overflow.
    /// Without overflow, explicit entries retain their labels and positions.
    static func capped(_ points: [Point], props: Props, valueScale: Double = 1) -> [Point] {
        guard let raw = props.double("maxCategories"), raw.isFinite, raw >= 1,
              raw.rounded(.down) == raw, raw < Double(points.count) else { return points }
        let keep = Int(raw) - 1
        let ranked = points.indices.filter { !points[$0].isOther }.sorted {
            if points[$0].isMissing != points[$1].isMissing { return !points[$0].isMissing }
            return points[$0].value == points[$1].value ? $0 < $1 : points[$0].value > points[$1].value
        }
        let selected = Set(ranked.prefix(keep))
        let retained = points.indices.filter { selected.contains($0) }.map { points[$0] }
        let folded = points.indices.filter { !selected.contains($0) }.map { points[$0] }
        let records = folded.flatMap(\.records)
        let value: Double
        if props.string("aggregate") == "avg", !records.isEmpty {
            let key = props.string("yKey") ?? props.string("valueKey") ?? ""
            let (total, scale) = sum(records.map { number($0[key]) ?? 0 })
            value = clamped(total / Double(records.count) * scale) / valueScale
        } else {
            let (total, scale) = sum(folded.map(\.value))
            value = clamped(total * scale)
        }
        var other = Point(id: keep, label: props.string("otherLabel") ?? "Other", value: value, records: records, isMissing: folded.allSatisfy(\.isMissing), isOther: true)
        other.includesOtherFlag = points.contains(where: \.includesOtherFlag)
        let result = retained + [other]
        return result.enumerated().map { index, point in
            point.reindexed(index)
        }
    }

    /// A supplied display is valid only for one contributing source row.
    static func sourceDisplay(_ records: [JSONValue], props: Props) -> String? {
        guard records.count == 1, let key = props.string("displayKey") else { return nil }
        return records[0][key]?.stringValue
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
