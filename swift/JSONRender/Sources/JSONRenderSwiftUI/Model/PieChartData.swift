import Foundation

/// The slices of a `PieChart`, shared by the SwiftUI and PDF renderers.
///
/// Built from the chart's resolved props: `data` (an array of objects, or an object whose
/// `data` member is one), `nameKey`, `valueKey` and an optional `aggregate`.
/// - Without `aggregate`, every record with a positive `valueKey` (a number or numeric string)
///   is one slice, in data order. A record without a name is labelled `"Segment N"` (its
///   1-based position in `data`).
/// - With `aggregate`, records are grouped and sorted by name like ``ChartData`` (`"sum"`,
///   `"avg"` or `"count"`); groups whose value is not positive are left out.
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

        public init(id: Int, label: String, value: Double, fraction: Double) {
            self.id = id
            self.label = label
            self.value = value
            self.fraction = fraction
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
            aggregate: props.enum("aggregate")
        )
    }

    public init(records: [JSONValue], nameKey: String, valueKey: String, aggregate: ChartData.Aggregate?) {
        let named: [(label: String, value: Double)]
        if let aggregate {
            named = ChartData(records: records, xKey: nameKey, yKey: valueKey, aggregate: aggregate)
                .points.map { ($0.label, $0.value) }
        } else {
            named = records.enumerated().compactMap { index, record in
                guard let value = ChartData.number(record[valueKey]) else { return nil }
                let name = record[nameKey].flatMap { $0 == .null ? nil : JS.toString($0) }
                return (name ?? "Segment \(index + 1)", value)
            }
        }
        let positive = named.filter { $0.value > 0 }
        let (total, scale) = ChartData.sum(positive.map(\.value))
        self.init(slices: positive.enumerated().map { index, slice in
            Slice(id: index, label: slice.label, value: slice.value, fraction: slice.value / scale / total)
        })
    }
}
