import Foundation

/// The slices of a `PieChart`, shared by the SwiftUI and PDF renderers.
///
/// Built from the chart's resolved props: `data` (an array of objects, or an object whose
/// `data` member is one), `nameKey`, `valueKey` and an optional `aggregate`.
/// - Without `aggregate`, every record with a positive `valueKey` (a number or numeric string)
///   is one slice, in data order. A record without a name is labelled `"Segment N"` (its
///   1-based position in `data`).
/// - With `aggregate`, records are grouped by their name as written (`"unknown"` without one;
///   dates are not merged by day) and sorted by name. `"sum"` and `"avg"` use only positive
///   values, and a name with none is left out; `"count"` counts every record of a name.
///
/// Fractions are computed from an overflow-safe total, so they stay finite and add up to 1.
public struct PieChartData: Sendable, Hashable {
    public struct Slice: Sendable, Hashable, Identifiable {
        /// Position among the slices; picks the slice's color.
        public let id: Int
        public let label: String
        public let value: Double
        /// Share of the total, 0...1.
        public let fraction: Double
        public let records: [JSONValue]
        public let isOther: Bool
        var includesOtherFlag = false
        var includesDisplay = false
        public let formattedValue: String?
        public var valueText: String { formattedValue ?? value.formatted() }

        public var datum: JSONValue {
            var payload: [String: JSONValue] = ["index": .number(Double(id)), "label": .string(label), "value": .number(value), "fraction": .number(fraction), "records": .array(records)]
            if includesOtherFlag { payload["isOther"] = .bool(isOther) }
            if includesDisplay { payload["display"] = .string(valueText) }
            return .object(payload)
        }

        public init(id: Int, label: String, value: Double, fraction: Double, records: [JSONValue] = [], isOther: Bool = false, formattedValue: String? = nil) {
            self.id = id
            self.label = label
            self.value = value
            self.fraction = fraction
            self.records = records
            self.isOther = isOther
            self.formattedValue = formattedValue
        }

        /// The rounded percentage, e.g. `"45%"`; `"<1%"` for a share under half a percent.
        public var percentText: String {
            let percent = (fraction * 100).rounded()
            return percent == 0 && fraction > 0 ? "<1%" : "\(Int(percent))%"
        }
    }

    /// A donut's inner radius, as a fraction of the outer radius.
    public static let donutRatio = 0.5

    public let slices: [Slice]

    /// Resolves Swift Charts' selected angle value (the sectors are plotted in fractions).
    public func slice(at fraction: Double) -> Slice? {
        guard fraction.isFinite, fraction >= 0, fraction < 1 else { return nil }
        var end = 0.0
        return slices.first { slice in
            end += slice.fraction
            return fraction < end
        }
    }

    public var isEmpty: Bool { slices.isEmpty }

    public init(slices: [Slice]) {
        self.slices = slices
    }

    /// Reads `data`, `nameKey`, `valueKey` and `aggregate` from a chart's resolved props.
    public init(props: Props) {
        self.init(
            records: ChartData.records(from: props["data"]),
            nameKey: props.string("nameKey") ?? "",
            valueKey: props.string("valueKey") ?? "",
            aggregate: props.enum("aggregate"),
            capProps: props
        )
    }

    public init(records: [JSONValue], nameKey: String, valueKey: String, aggregate: ChartData.Aggregate?, capProps: Props = Props([:])) {
        func name(_ record: JSONValue) -> String? {
            record[nameKey].flatMap { $0 == .null ? nil : JS.toString($0) }
        }
        func positive(_ record: JSONValue) -> Double? {
            ChartData.number(record[valueKey]).flatMap { $0 > 0 ? $0 : nil }
        }
        // Each slice's name and its positive values (one per slice without `aggregate`).
        var groups: [(label: String, values: [Double], records: [JSONValue])] = []
        switch aggregate {
        case nil:
            groups = records.enumerated().compactMap { index, record in
                positive(record).map { (name(record) ?? "Segment \(index + 1)", [$0], [record]) }
            }
        case let aggregate?:
            // Grouped by the name as written (no date grouping), sorted like ChartData. sum and
            // avg use positive values only; count counts every record, whatever its value.
            var byName: [String: [Double]] = [:]
            var recordsByName: [String: [JSONValue]] = [:]
            for record in records {
                let value = aggregate == .count ? 1 : positive(record)
                guard let value else { continue }
                let key = name(record) ?? "unknown"
                byName[key, default: []].append(value)
                recordsByName[key, default: []].append(record)
            }
            groups = byName.keys.sorted(by: JS.lessThan).map { key in
                (key, byName[key] ?? [], recordsByName[key] ?? [])
            }
        }
        // Slice values in units of `scale`: 1, or 2⁶⁴ when a sum would overflow, so fractions
        // come from unclamped totals.
        func values(scale: Double) -> [Double] {
            groups.map { group in
                let total = group.values.reduce(0) { $0 + $1 / scale }
                return aggregate == .avg ? total / Double(group.values.count) : total
            }
        }
        var scale = 1.0
        var scaled = values(scale: scale)
        if !scaled.reduce(0, +).isFinite || !scaled.allSatisfy(\.isFinite) {
            scale = 0x1p64
            scaled = values(scale: scale)
        }
        let points = zip(groups, scaled).enumerated().map { index, pair in
            var point = ChartData.Point(id: index, label: pair.0.label, value: pair.1, records: pair.0.records)
            if let key = capProps.string("otherKey") {
                point.isOther = point.records.contains { JS.isTruthy($0[key]) }
                point.includesOtherFlag = true
            }
            return point
        }
        let capped = ChartData.capped(points, props: capProps, valueScale: scale)
        let total = capped.reduce(0) { $0 + $1.value }
        self.init(slices: capped.map {
            let value = ChartData.clamped($0.value * scale)
            let includesDisplay = capProps.string("displayKey") != nil
            let formatted = ChartData.sourceDisplay($0.records, props: capProps)
                ?? ChartValueFormatting.string(value, props: capProps)
                ?? (includesDisplay ? value.formatted() : nil)
            var slice = Slice(id: $0.id, label: $0.label, value: value, fraction: $0.value / total, records: $0.records, isOther: $0.isOther, formattedValue: formatted)
            slice.includesOtherFlag = $0.includesOtherFlag
            slice.includesDisplay = includesDisplay
            return slice
        })
    }
}
