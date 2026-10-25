import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import JSONRenderPDF
import JSONRenderSwiftUI

struct RenderedPDF {
    var data: Data
    var pages: [DrawnPage]
    var document: PDFDocument

    var pageCount: Int { document.pageCount }

    func text(page index: Int) -> String {
        document.page(at: index)?.string ?? ""
    }

    var allText: String { document.string ?? "" }

    func items(_ kind: DrawnItem.Kind) -> [(page: Int, item: DrawnItem)] {
        pages.enumerated().flatMap { index, page in
            page.items.filter { $0.kind == kind }.map { (index, $0) }
        }
    }
}

enum PDFTestSupport {
    /// Renders with placeholders for images unless a loader is given (deterministic, offline).
    static func render(
        _ spec: Spec, loader: PDFImageLoader = .placeholders, state: [String: JSONValue] = [:]
    ) async throws -> RenderedPDF {
        let renderer = PDFRenderer(options: .init(state: state, imageLoader: loader, imageTimeout: .seconds(5)))
        let output = try await renderer.renderWithReport(spec)
        let document = try #require(PDFDocument(data: output.data))
        return RenderedPDF(data: output.data, pages: output.pages, document: document)
    }

    /// Rasterizes one PDF page to PNG bytes at `height` pixels (white background), drawing
    /// annotations (form widgets) through PDFKit.
    static func png(_ data: Data, page index: Int, height: CGFloat = 1200) -> Data? {
        guard let document = PDFDocument(data: data), let page = document.page(at: index) else { return nil }
        let box = page.bounds(for: .mediaBox)
        let scale = height / box.height
        let width = Int((box.width * scale).rounded()), pixelHeight = Int(height)
        guard let context = CGContext(
            data: nil, width: width, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// A 2×1 red PNG for image-loader tests.
    static let samplePNG: Data = {
        let context = CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }()
}
