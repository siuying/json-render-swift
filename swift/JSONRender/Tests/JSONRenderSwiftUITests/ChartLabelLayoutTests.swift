#if os(macOS)
import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
import Vision
@testable import JSONRenderSwiftUI

@Suite("Chart label layout")
@MainActor
struct ChartLabelLayoutTests {
    @Test func horizontalLabelsSitInsideTheirBarBands() async throws {
        let props = Props(["title": "Revenue", "horizontal": true, "height": 300, "color": "#ff0000", "xKey": "x", "yKey": "y", "data": [["x": "Alpha", "y": 12], ["x": "Bravo", "y": 8], ["x": "Charlie", "y": 10]]])
        let element = try #require(Element(json: ["type": "BarChart", "props": .object(props.values)]))
        let context = ComponentContext(key: "chart", element: element, props: props, session: FormSession(), bindings: [:], ancestors: [], localValues: .constant([:]))
        _ = NSApplication.shared
        let view = ChartComponent(context: context, kind: .bar).frame(width: 400, height: 340, alignment: .top).background(Color.white).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 340)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let image = try #require(representation.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bitmap = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var bands: [ClosedRange<Int>] = []
        var start: Int?
        for y in 0..<height {
            let redCount = (0..<width).filter { x in
                let offset = (y * width + x) * 4
                return pixels[offset] > 180 && pixels[offset + 1] < 80 && pixels[offset + 2] < 80
            }.count
            if redCount > 30 { if start == nil { start = y } }
            else if let first = start { bands.append(first...(y - 1)); start = nil }
        }
        #expect(bands.count == 3)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let url = URL(fileURLWithPath: "/tmp/charts-a-shots/c1-horizontal-hosted.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        for (index, label) in ["Alpha", "Bravo", "Charlie"].enumerated() {
            let text = try #require(request.results?.first { $0.topCandidates(1).first?.string.hasPrefix(label) == true })
            let y = Int((1 - text.boundingBox.midY) * Double(height))
            #expect(bands[index].contains(y), "\(label) at y=\(y), bar band \(bands[index])")
        }

    }
}

#endif
