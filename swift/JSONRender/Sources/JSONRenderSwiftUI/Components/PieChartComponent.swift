import Charts
import SwiftUI

/// `PieChart` — `title`, `data`, `nameKey`, `valueKey`, `aggregate`, `donut`, `colors`,
/// `legend`, `height`. Swift Charts sectors over ``PieChartData``, from 12 o'clock clockwise
/// in slice order, colored from `colors` (or ``ChartColors/palette``) in turn; `donut` cuts
/// out the middle half. Below it, a legend row per slice: swatch, name and percentage.
struct PieChartComponent: View {
    let context: ComponentContext
    @ScaledMetric(relativeTo: .footnote) private var swatchSize = 10.0

    var body: some View {
        let data = PieChartData(props: context.props)
        let colors = ChartColors.list(context.props["colors"]).compactMap { Color(chartHex: $0) }
        ChartFrame(title: context.props.string("title"), isEmpty: data.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                Chart(data.slices) { slice in
                    SectorMark(
                        angle: .value("Share", slice.fraction),
                        innerRadius: .ratio(context.props.bool("donut") == true ? PieChartData.donutRatio : 0),
                        angularInset: 1
                    )
                    // Keyed by position, so repeated names keep their own colors.
                    .foregroundStyle(by: .value("Slice", String(slice.id)))
                    .accessibilityLabel(slice.label)
                    .accessibilityValue("\(slice.value.formatted()), \(slice.percentText)")
                }
                .accessibilityChartDescriptor(ChartAccessibility(
                    title: context.props.string("title"), summary: context.props.string("accessibilitySummary"),
                    data: ChartData(points: data.slices.map { .init(id: $0.id, label: $0.label, value: $0.value) }, valueKey: context.props.string("valueKey") ?? "Value"), radial: true))
                .id(data)
                .chartForegroundStyleScale(
                    domain: data.slices.map { String($0.id) },
                    range: data.slices.map { colors[$0.id % colors.count] }
                )
                .chartLegend(.hidden)
                .frame(height: ChartData.height(context.props))
                if context.props.bool("legend") != false {
                    legend(data, colors: colors)
                }
            }
        }
    }

    private func legend(_ data: PieChartData, colors: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(data.slices) { slice in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colors[slice.id % colors.count])
                        .frame(width: swatchSize, height: swatchSize)
                    Text(slice.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(slice.percentText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.footnote)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
