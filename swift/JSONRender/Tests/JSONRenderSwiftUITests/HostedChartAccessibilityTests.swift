#if os(macOS)
import Accessibility
import AppKit
import SwiftUI
import Testing
@testable import JSONRenderSwiftUI

@Suite("Hosted chart accessibility", .serialized)
@MainActor
struct HostedChartAccessibilityTests {
    @Test(arguments: ["BarChart", "LineChart", "AreaChart", "PieChart"])
    func sourceDisplaysReachNativeValuesAudioGraphAndPress(_ type: String) async throws {
        let spec = Spec(json: ["root": "chart", "elements": ["chart": ["type": .string(type), "props": ["xKey": "x", "yKey": "y", "nameKey": "x", "valueKey": "y", "displayKey": "text", "valueFormat": ["style": "percent"], "data": [["x": "A", "y": 0.5, "text": "Half done"], ["x": "B", "y": 0.5, "text": "Thirty seconds"]]], "on": ["press": ["action": "capture", "params": ["value": ["$datum": ""]]]]]]])
        let session = FormSession(spec: spec)
        var captured: JSONValue?
        session.actions.register("capture") { params, _ in captured = params["value"] }
        _ = NSApplication.shared
        let host = NSHostingView(rootView: JSONRenderView(session: session).frame(width: 400, height: 500))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        func nodes() -> [any NSAccessibilityProtocol] {
            var visited = Set<ObjectIdentifier>()
            func walk(_ object: AnyObject) -> [any NSAccessibilityProtocol] {
                guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
                let node = object as? any NSAccessibilityProtocol
                let children = (node?.accessibilityChildren() ?? []) + ((object as? NSView)?.subviews ?? [])
                return (node.map { [$0] } ?? []) + children.flatMap { walk($0 as AnyObject) }
            }
            return walk(host)
        }
        var available: [any NSAccessibilityProtocol] = []
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            available = nodes()
            if available.contains(where: { $0.accessibilityIdentifier() == "chart-mark-0" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let mark = try #require(available.first { $0.accessibilityIdentifier() == "chart-mark-0" })
        #expect((mark.accessibilityValue() as? String)?.hasPrefix("Half done") == true)
        let graph = try #require(available.first { $0.accessibilityIdentifier() == "chart-chart" } as? any AXChart)
        let descriptor = try #require(graph.accessibilityChartDescriptor)
        #expect(descriptor.series.first?.dataPoints.map(\.label) == ["A: Half done", "B: Thirty seconds"])
        #expect(mark.accessibilityPerformPress())
        for _ in 0..<100 where captured == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(captured?["display"] == "Half done")
        #expect(captured?["value"] == 0.5)
    }

    @Test func accessibleMarkActivatesOnceAndAudioGraphRemainsAvailable() async throws {
        let spec = Spec(json: ["root": "chart", "state": ["horizontal": false, "rows": [["x": "West", "y": 12, "rest": true], ["x": "Unknown", "y": nil], ["x": "Zero", "y": 0]]], "elements": ["chart": ["type": "BarChart", "props": ["title": "Revenue", "otherKey": "rest", "otherColor": "#888888", "horizontal": ["$state": "/horizontal"], "missing": "show", "xKey": "x", "yKey": "y", "data": ["$state": "/rows"]], "on": ["press": ["action": "capture", "params": ["value": ["$datum": ""]]]]]]])
        let session = FormSession(spec: spec)
        var captured: [JSONValue] = []
        session.actions.register("capture") { params, _ in captured.append(params["value"] ?? .null) }
        _ = NSApplication.shared
        let host = NSHostingView(rootView: JSONRenderView(session: session).frame(width: 400, height: 400))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }

        func nodes() -> [any NSAccessibilityProtocol] {
            var visited = Set<ObjectIdentifier>()
            func walk(_ object: AnyObject) -> [any NSAccessibilityProtocol] {
                guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
                let node = object as? any NSAccessibilityProtocol
                let children = (node?.accessibilityChildren() ?? []) + ((object as? NSView)?.subviews ?? [])
                return (node.map { [$0] } ?? []) + children.flatMap { walk($0 as AnyObject) }
            }
            return walk(host)
        }

        for horizontal in [false, true] {
            if horizontal {
                session.store.set(-12, at: "/rows/0/y")
                session.store.set(false, at: "/rows/0/rest")
            }
            session.store.set(.bool(horizontal), at: "/horizontal")
            var available: [any NSAccessibilityProtocol] = []
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                available = nodes()
                if available.contains(where: { $0.accessibilityIdentifier() == "chart-mark-0" }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let west = try #require(available.first { $0.accessibilityIdentifier() == "chart-mark-0" })
            let unknown = try #require(available.first { $0.accessibilityIdentifier() == "chart-mark-1" })
            #expect(west.accessibilityLabel() == "West")
            #expect(unknown.accessibilityValue() as? String == "n/a")
            for id in 0...2 {
                let mark = try #require(available.first { $0.accessibilityIdentifier() == "chart-mark-\(id)" })
                #expect(mark.accessibilityFrame().width > 0)
                #expect(mark.accessibilityFrame().height > 0)
            }
            #expect(west.accessibilityFrame().width > 0)
            #expect(west.accessibilityFrame().height > 0)
            let graph = try #require(available.first { $0.accessibilityIdentifier() == "chart-chart" } as? any AXChart)
            let descriptor = try #require(graph.accessibilityChartDescriptor)
            #expect(descriptor.title == "Revenue")
            #expect(descriptor.series.first?.dataPoints.count == 2, "n/a is excluded from numeric audio samples")
            let count = captured.count
            #expect(west.accessibilityPerformPress())
            for _ in 0..<100 where captured.count == count { try await Task.sleep(for: .milliseconds(10)) }
            #expect(captured.count == count + 1)
            #expect(captured.last?["label"] == "West")
            #expect(captured.last?["isOther"] == .bool(!horizontal))
            #expect(captured.last?["value"] == (horizontal ? -12 : 12))
            #expect(unknown.accessibilityPerformPress())
            for _ in 0..<100 where captured.count == count + 1 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(captured.count == count + 2)
            #expect(captured.last?["value"] == .null)
        }
    }
}
#endif
