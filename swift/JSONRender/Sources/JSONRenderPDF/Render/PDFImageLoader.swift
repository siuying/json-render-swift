import CoreGraphics
import Foundation
import ImageIO
import Synchronization

/// Loads the bytes of an `Image` `src`. Failures (thrown errors, undecodable data,
/// timeouts, exceeded budgets) never fail the render: the image is drawn as a neutral
/// placeholder box.
///
/// Loaders should honour task cancellation; the renderer stops waiting for a load at
/// its deadline either way.
public struct PDFImageLoader: Sendable {
    public typealias Load = @Sendable (_ source: String) async throws -> Data

    let load: Load

    public init(_ load: @escaping Load) {
        self.load = load
    }

    /// `http(s)` (streamed, at most 10 MB) and `data:` URLs (at most 10 MB decoded).
    /// Local files are never read; use ``files(in:)`` to opt in.
    public static let `default` = http()

    /// `http(s)` and `data:` URLs, each capped at `maxBytes`.
    public static func http(maxBytes: Int = 10_000_000) -> PDFImageLoader {
        PDFImageLoader { source in
            if isDataURL(source) {
                guard let data = dataURL(source, maxBytes: maxBytes) else { throw URLError(.cannotDecodeContentData) }
                return data
            }
            guard let url = URL(string: source), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { throw URLError(.unsupportedURL) }
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            if response.expectedContentLength > Int64(maxBytes) { throw URLError(.dataLengthExceedsMaximum) }
            var data = Data()
            data.reserveCapacity(Int(max(min(response.expectedContentLength, Int64(maxBytes)), 0)))
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
            }
            return data
        }
    }

    /// Opt-in local images: `file:` URLs (or paths) inside `directory` only, plus
    /// everything ``default`` loads.
    public static func files(in directory: URL, maxBytes: Int = 10_000_000) -> PDFImageLoader {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let remote = http(maxBytes: maxBytes)
        return PDFImageLoader { source in
            let url = source.hasPrefix("/") ? URL(fileURLWithPath: source) : URL(string: source)
            guard let url, url.isFileURL else { return try await remote.load(source) }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
                throw URLError(.noPermissionsToReadFile)
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            guard size <= maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
    }

    /// Tries this loader first and `fallback` when it throws, e.g. bundled assets with the
    /// network as a fallback:
    ///
    /// ```swift
    /// PDFImageLoader { source in try bundledImage(named: source) }.fallback(.default)
    /// ```
    public func fallback(_ fallback: PDFImageLoader) -> PDFImageLoader {
        PDFImageLoader { [load] source in
            do {
                return try await load(source)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return try await fallback.load(source)
            }
        }
    }

    /// Never loads anything: every image renders as a placeholder (deterministic output).
    public static let placeholders = PDFImageLoader { _ in throw URLError(.cancelled) }

    static func isDataURL(_ source: String) -> Bool {
        source.prefix(5).lowercased() == "data:"
    }

    /// Decodes `data:[<mediatype>][;base64],<data>`, refusing payloads over `maxBytes`.
    static func dataURL(_ source: String, maxBytes: Int = 10_000_000) -> Data? {
        guard isDataURL(source), let comma = source.firstIndex(of: ",") else { return nil }
        let header = source[source.index(source.startIndex, offsetBy: 5)..<comma].lowercased()
        let payload = source[source.index(after: comma)...]
        if header.hasSuffix(";base64") {
            guard payload.utf8.count / 4 * 3 <= maxBytes + 3 else { return nil }
            return Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters)
        }
        guard payload.utf8.count <= maxBytes * 3 else { return nil }
        return String(payload).removingPercentEncoding.map { Data($0.utf8) }.flatMap { $0.count <= maxBytes ? $0 : nil }
    }
}

/// Resource budgets for images in one render.
public struct PDFImageLimits: Sendable, Hashable {
    /// Bytes accepted from a loader for one image.
    public var maxBytesPerImage: Int
    /// Bytes accepted across all images of a document.
    public var maxTotalBytes: Int
    /// Decoded pixels (width × height) accepted for one image.
    public var maxPixelsPerImage: Int
    /// Images loaded at the same time.
    public var maxConcurrentLoads: Int
    /// Longest side, in pixels, images are downsampled to before drawing.
    public var maxDrawDimension: Int

    public init(
        maxBytesPerImage: Int = 10_000_000,
        maxTotalBytes: Int = 50_000_000,
        maxPixelsPerImage: Int = 40_000_000,
        maxConcurrentLoads: Int = 4,
        maxDrawDimension: Int = 2_048
    ) {
        self.maxBytesPerImage = maxBytesPerImage
        self.maxTotalBytes = maxTotalBytes
        self.maxPixelsPerImage = maxPixelsPerImage
        self.maxConcurrentLoads = maxConcurrentLoads
        self.maxDrawDimension = maxDrawDimension
    }
}

/// A decoded-size-checked image ready for layout and drawing.
struct LoadedImage: Sendable {
    var data: Data
    var pixelSize: CGSize
    var maxDrawDimension: Int

    /// `nil` when ImageIO cannot read the header or the image exceeds `maxPixels`.
    init?(data: Data, maxPixels: Int = 40_000_000, maxDrawDimension: Int = 2_048) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= Double(maxPixels)
        else { return nil }
        self.data = data
        self.maxDrawDimension = maxDrawDimension
        pixelSize = CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    /// Decodes, downsampling so the longest side is at most `maxDrawDimension`.
    func makeImage() -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if max(pixelSize.width, pixelSize.height) <= CGFloat(maxDrawDimension) {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDrawDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

extension PDFImageLoader {
    struct Batch: Sendable {
        var images: [String: LoadedImage] = [:]
        var failed: Set<String> = []
    }

    /// Loads sources with bounded concurrency, a per-image deadline and byte/pixel budgets.
    func loadAll(_ sources: Set<String>, timeout: Duration, limits: PDFImageLimits) async -> Batch {
        var batch = Batch()
        var totalBytes = 0
        let ordered = sources.sorted()
        await withTaskGroup(of: (String, Data?).self) { group in
            var next = 0
            func enqueue() {
                guard next < ordered.count else { return }
                let source = ordered[next]
                next += 1
                group.addTask { [load] in (source, await Self.withDeadline(timeout) { try await load(source) }) }
            }
            for _ in 0..<max(limits.maxConcurrentLoads, 1) { enqueue() }
            while let (source, data) = await group.next() {
                enqueue()
                guard !Task.isCancelled, let data, data.count <= limits.maxBytesPerImage,
                      totalBytes + data.count <= limits.maxTotalBytes,
                      let image = LoadedImage(data: data, maxPixels: limits.maxPixelsPerImage, maxDrawDimension: limits.maxDrawDimension)
                else {
                    batch.failed.insert(source)
                    continue
                }
                totalBytes += data.count
                batch.images[source] = image
            }
        }
        return batch
    }

    /// Runs `operation`, giving up after `timeout` (or on cancellation) without waiting
    /// for an operation that ignores cancellation; such an operation finishes detached.
    static func withDeadline(_ timeout: Duration, _ operation: @escaping @Sendable () async throws -> Data) async -> Data? {
        let once = Once()
        let work = Task { once.resume(try? await operation()) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            once.resume(nil)
        }
        return await withTaskCancellationHandler {
            let result = await once.value()
            work.cancel()
            timer.cancel()
            return result
        } onCancel: {
            once.resume(nil)
        }
    }

    /// A value delivered at most once, awaitable once.
    private final class Once: Sendable {
        private struct State {
            var value: Data??
            var waiter: CheckedContinuation<Data?, Never>?
        }

        private let state = Mutex(State())

        func resume(_ data: Data?) {
            let waiter = state.withLock { state -> CheckedContinuation<Data?, Never>? in
                guard state.value == nil else { return nil }
                state.value = .some(data)
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: data)
        }

        func value() async -> Data? {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Data?? in
                    if let value = state.value { return value }
                    state.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}
