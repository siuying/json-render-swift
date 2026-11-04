#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import JSONRenderSwiftUI

@Suite("Isolated chart points", .serialized)
@MainActor
struct IsolatedChartPointTests {
    /// Count separated columns of red pixels. Axes and n/a markers are neutral.
    private func redBands(_ host: NSHostingView<some View>) throws -> Int {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 340,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        var pixels = [UInt8](repeating: 0, count: 400 * 340 * 4)
        let context = try #require(CGContext(data: &pixels, width: 400, height: 340, bitsPerComponent: 8,
            bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 400, height: 340))
        var count = 0
        var previous = false
        for x in 0..<400 {
            let red = (0..<340).contains { y in
                let offset = (y * 400 + x) * 4
                return pixels[offset] > 180 && pixels[offset + 1] < 80 && pixels[offset + 2] < 80
            }
            if red && !previous { count += 1 }
            previous = red
        }
        return count
    }

    @Test(arguments: ["LineChart", "AreaChart"])
    func singleAndIsolatedValuesRemainVisibleDuringLiveUpdates(_ type: String) async throws {
        let session = FormSession(spec: Spec(json: ["root": "chart", "state": ["rows": []], "elements": [
            "chart": ["type": .string(type), "props": ["data": ["$state": "/rows"], "xKey": "x", "yKey": "y", "missing": "show", "color": "#ff0000", "height": 300]]
        ]]))
        _ = NSApplication.shared
        let host = NSHostingView(rootView: JSONRenderView(session: session).frame(width: 400, height: 340).background(.white).environment(\.colorScheme, .light))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 340)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        // Connected run -> isolated samples -> a single value -> connected run.
        for (values, bands): ([JSONValue], Int) in [([3, 2, 1], 1), ([3, .null, 1], 2), ([3], 1), ([.null, 3, .null, 1, .null], 2), ([3, 2, 1], 1)] {
            let rows = values.enumerated().map { index, value in JSONValue.object(["x": .string("p\(index)"), "y": value]) }
            session.store.set(.array(rows), at: "/rows")
            try await Task.sleep(for: .milliseconds(60))
            #expect(try redBands(host) == bands, "\(type) must display every isolated numeric value in \(values)")
        }
    }
}
#endif
