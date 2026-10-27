import Accessibility
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Frames come from ChartProxy, so touch, VoiceOver focus and automation refer to
/// the same mark. Values and descriptors remain independent of gesture delivery.
struct ChartAccessibleMark: Equatable, Sendable {
    let id: Int
    let label: String
    let value: String
    let datum: JSONValue
    let frame: CGRect
}

struct ChartAccessibilityLayout: Equatable, Sendable {
    var plot: CGRect = .zero
    var marks: [ChartAccessibleMark] = []
}

struct ChartAccessibilityLayoutKey: PreferenceKey {
    static let defaultValue = ChartAccessibilityLayout()
    static func reduce(value: inout ChartAccessibilityLayout, nextValue: () -> ChartAccessibilityLayout) {
        value = nextValue()
    }
}

struct ChartAccessibilityOverlay: View {
    let context: ComponentContext
    let layout: ChartAccessibilityLayout
    let descriptor: ChartAccessibility

    private var pressAction: (@MainActor (JSONValue) -> Void)? {
        guard context.element.on["press"] != nil else { return nil }
        return { datum in context.emit("press", datum: datum) }
    }

    var body: some View {
        ChartNativeAccessibility(key: context.key, title: context.props.string("title") ?? String(localized: "Chart"),
            layout: layout, descriptor: descriptor, onPress: pressAction)
            .accessibilityChartDescriptor(descriptor)
    }
}

#if canImport(UIKit)
struct ChartNativeAccessibility: UIViewRepresentable {
    let key: String
    let title: String
    let layout: ChartAccessibilityLayout
    let descriptor: ChartAccessibility
    let onPress: (@MainActor (JSONValue) -> Void)?

    func makeUIView(context: Context) -> ChartAccessibilityPlatformView { ChartAccessibilityPlatformView() }
    func updateUIView(_ view: ChartAccessibilityPlatformView, context: Context) {
        view.update(key: key, title: title, layout: layout, descriptor: descriptor, onPress: onPress)
    }
}

final class ChartAccessibilityNode: UIAccessibilityElement, @preconcurrency AXChart {
    var accessibilityChartDescriptor: AXChartDescriptor?
    var activate: (@MainActor () -> Void)?
    override func accessibilityActivate() -> Bool {
        guard let activate else { return false }
        activate()
        return true
    }
}

final class ChartAccessibilityPlatformView: UIView {
    private lazy var graph = ChartAccessibilityNode(accessibilityContainer: self)
    private var nodes: [Int: ChartAccessibilityNode] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    func update(key: String, title: String, layout: ChartAccessibilityLayout, descriptor: ChartAccessibility,
                onPress: (@MainActor (JSONValue) -> Void)?) {
        graph.accessibilityIdentifier = "\(key)-chart"
        graph.accessibilityLabel = title
        graph.accessibilityValue = descriptor.summaryText
        graph.accessibilityTraits = .image
        graph.accessibilityFrameInContainerSpace = layout.plot
        graph.accessibilityChartDescriptor = descriptor.makeChartDescriptor()
        var next: [Int: ChartAccessibilityNode] = [:]
        var children: [UIAccessibilityElement] = [graph]
        for item in layout.marks {
            let node = nodes[item.id] ?? ChartAccessibilityNode(accessibilityContainer: self)
            node.accessibilityIdentifier = "\(key)-mark-\(item.id)"
            node.accessibilityLabel = item.label
            node.accessibilityValue = item.value
            node.accessibilityTraits = onPress == nil ? .staticText : .button
            node.accessibilityFrameInContainerSpace = item.frame
            if let onPress { node.activate = { onPress(item.datum) } }
            else { node.activate = nil }
            next[item.id] = node
            children.append(node)
        }
        nodes = next
        accessibilityElements = children
    }
}
#else
struct ChartNativeAccessibility: NSViewRepresentable {
    let key: String
    let title: String
    let layout: ChartAccessibilityLayout
    let descriptor: ChartAccessibility
    let onPress: (@MainActor (JSONValue) -> Void)?

    func makeNSView(context: Context) -> ChartAccessibilityPlatformView { ChartAccessibilityPlatformView() }
    func updateNSView(_ view: ChartAccessibilityPlatformView, context: Context) {
        view.update(key: key, title: title, layout: layout, descriptor: descriptor, onPress: onPress)
    }
}

// AppKit invokes accessibility actions on the main thread. The inherited AX API
// is nonisolated; forwarding below re-enters that actor explicitly.
final class ChartAccessibilityNode: NSAccessibilityElement, AXChart {
    var accessibilityChartDescriptor: AXChartDescriptor?
    var activate: (@MainActor () -> Void)?
    weak var chartView: NSView?
    var localFrame: CGRect = .zero

    override func accessibilityFrame() -> NSRect {
        guard let chartView else { return .zero }
        return NSAccessibility.screenRect(fromView: chartView, rect: localFrame)
    }
    override func accessibilityPerformPress() -> Bool {
        let action = activate
        return MainActor.assumeIsolated {
            guard let action else { return false }
            action()
            return true
        }
    }
}

final class ChartAccessibilityPlatformView: NSView {
    private let graph = ChartAccessibilityNode()
    private var nodes: [Int: ChartAccessibilityNode] = [:]
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(key: String, title: String, layout: ChartAccessibilityLayout, descriptor: ChartAccessibility,
                onPress: (@MainActor (JSONValue) -> Void)?) {
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        graph.chartView = self
        graph.setAccessibilityParent(self)
        graph.setAccessibilityIdentifier("\(key)-chart")
        graph.setAccessibilityLabel(title)
        graph.setAccessibilityValue(descriptor.summaryText)
        graph.setAccessibilityRole(.image)
        graph.localFrame = layout.plot
        graph.accessibilityChartDescriptor = descriptor.makeChartDescriptor()
        var next: [Int: ChartAccessibilityNode] = [:]
        var children: [ChartAccessibilityNode] = [graph]
        for item in layout.marks {
            let node = nodes[item.id] ?? ChartAccessibilityNode()
            node.chartView = self
            node.setAccessibilityParent(self)
            node.setAccessibilityIdentifier("\(key)-mark-\(item.id)")
            node.setAccessibilityLabel(item.label)
            node.setAccessibilityValue(item.value)
            node.setAccessibilityRole(onPress == nil ? .staticText : .button)
            node.localFrame = item.frame
            if let onPress { node.activate = { onPress(item.datum) } }
            else { node.activate = nil }
            next[item.id] = node
            children.append(node)
        }
        nodes = next
        setAccessibilityChildren(children)
    }
}
#endif
