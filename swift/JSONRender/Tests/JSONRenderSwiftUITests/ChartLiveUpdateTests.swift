import SwiftUI
import Testing
@testable import JSONRenderSwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@Suite("Live chart updates", .serialized)
@MainActor
struct ChartLiveUpdateTests {
    @Test func mountedChartSurvivesOrientationAndDataChanges() async throws {
        let fixture = try Fixtures.json("charts/bar-live.json")
        let session = FormSession(spec: Spec(json: fixture))
        let root = JSONRenderView(session: session).frame(width: 390, height: 600)
        #if canImport(UIKit)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        #else
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        #endif
        for data: JSONValue in [[], [["x": "A long category label that wraps", "y": 3], ["x": 42, "y": "bad"], ["x": true, "y": "8"]], [], [["x": "B", "y": -4]]] {
            session.store.set(data, at: "/rows")
            for horizontal in [false, true, false, true] {
                session.store.set(.bool(horizontal), at: "/horizontal")
                try await Task.sleep(for: .milliseconds(40))
                #if canImport(UIKit)
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                #expect(host.sizeThatFits(in: window.bounds.size).height > 0)
                #else
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                #expect(host.fittingSize.height > 0)
                #endif
            }
        }
        #expect(session.store.value(at: "/horizontal") == true)
        #expect(ChartData(props: Props(["data": session.store.value(at: "/rows")!, "xKey": "x", "yKey": "y"])).points.map(\.value) == [-4])
    }
}
