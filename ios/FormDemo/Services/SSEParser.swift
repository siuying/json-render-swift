import Foundation

/// One server-sent event.
struct SSEEvent: Sendable, Hashable {
    /// The `event:` field; `nil` means the default `"message"` type.
    var event: String?
    /// The `data:` lines joined with `"\n"`.
    var data: String
    var id: String?
}

/// Incremental parser for `text/event-stream` (WHATWG HTML §9.2).
///
/// Feed raw bytes as they arrive, in chunks of any size; complete events come out.
/// Lines end with LF, CRLF or CR, and a blank line dispatches the pending event.
///
/// The parser splits lines itself instead of using `AsyncBytes.lines`, because
/// `AsyncLineSequence` drops empty lines, and in SSE the empty line is what ends
/// an event.
struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var lastByteWasCR = false
    private var eventType: String?
    private var dataLines: [String] = []
    private var lastEventID: String?

    /// Feeds one byte. Returns an event when this byte completes one.
    mutating func push(_ byte: UInt8) -> SSEEvent? {
        switch byte {
        case 0x0A where lastByteWasCR:
            // The LF of a CRLF pair; the CR already ended the line.
            lastByteWasCR = false
            return nil
        case 0x0A, 0x0D:
            lastByteWasCR = byte == 0x0D
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            return consume(line: text)
        default:
            lastByteWasCR = false
            line.append(byte)
            return nil
        }
    }

    /// Feeds a chunk of bytes, returning every event it completes.
    mutating func push(contentsOf bytes: some Sequence<UInt8>) -> [SSEEvent] {
        bytes.compactMap { push($0) }
    }

    /// Handles a stream that ends without a final blank line: an unterminated
    /// last line is processed, then any pending event is dispatched.
    mutating func finish() -> SSEEvent? {
        if !line.isEmpty {
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll()
            if let event = consume(line: text) { return event }
        }
        return dispatch()
    }

    /// Processes one complete line (without its terminator).
    mutating func consume(line: String) -> SSEEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }  // comment / keep-alive

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "event": eventType = String(value)
        case "data": dataLines.append(String(value))
        case "id" where !value.contains("\0"): lastEventID = String(value)
        default: break  // "retry" and unknown fields are ignored
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventType = nil
            dataLines.removeAll()
        }
        guard !dataLines.isEmpty else { return nil }
        let type = eventType.flatMap { $0.isEmpty ? nil : $0 }
        return SSEEvent(event: type, data: dataLines.joined(separator: "\n"), id: lastEventID)
    }
}
