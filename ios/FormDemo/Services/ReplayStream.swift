import Foundation

/// Plays recorded LLM output back as a text stream, split into token-sized chunks
/// that ignore line boundaries, like a real model stream.
enum ReplayStream {
    /// Splits `text` into chunks of 4–27 characters. Deterministic, so replays and
    /// tests always see the same boundaries.
    static func chunks(of text: String, seed: UInt64 = 0x2545F4914F6CDD1D) -> [String] {
        var generator = SplitMix64(state: seed)
        var chunks: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            let size = 4 + Int(generator.next() % 24)
            chunks.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return chunks
    }

    /// Yields `chunks` with `delay` between them. Stops early when cancelled.
    static func stream(_ chunks: [String], delay: Duration) -> AsyncThrowingStream<TextStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for chunk in chunks {
                        if delay > .zero { try await Task.sleep(for: delay) }
                        continuation.yield(.text(chunk))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Small deterministic PRNG (SplitMix64).
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
