import Foundation

/// Holds incomplete words across token boundaries without changing whitespace.
struct WordStreamBuffer {
    private(set) var pending = ""

    mutating func append(_ text: String) { pending += text }

    mutating func next(finishing: Bool) -> String? {
        guard !pending.isEmpty else { return nil }
        var end = pending.startIndex
        while end < pending.endIndex, pending[end].isWhitespace { end = pending.index(after: end) }
        if end == pending.endIndex {
            guard finishing else { return nil }
        } else if Self.isCJK(pending[end]) {
            end = pending.index(after: end)
        } else {
            repeat { end = pending.index(after: end) }
            while end < pending.endIndex && !pending[end].isWhitespace && !Self.isCJK(pending[end])
            // The next token may be the rest of this word.
            if end == pending.endIndex && !finishing { return nil }
        }
        while end < pending.endIndex, pending[end].isWhitespace { end = pending.index(after: end) }
        let word = String(pending[..<end])
        pending.removeSubrange(..<end)
        return word
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x3400...0x9FFF).contains(value) || (0x20000...0x323AF).contains(value)
            || (0x3040...0x30FF).contains(value) || (0xAC00...0xD7AF).contains(value)
    }
}

@MainActor
final class WordStreamRenderer {
    private var buffer = WordStreamBuffer()
    private var worker: Task<Void, Never>?
    private var finishing = false
    private var cancelled = false
    private let interval: UInt64
    private let reveal: (String) -> Void
    private(set) var receivedText = false

    init(interval: UInt64 = 35_000_000, reveal: @escaping (String) -> Void) {
        self.interval = interval
        self.reveal = reveal
    }

    func append(_ text: String) {
        guard !cancelled, !text.isEmpty else { return }
        receivedText = true
        buffer.append(text)
        startWorker()
    }

    func finish() async {
        finishing = true
        startWorker()
        await worker?.value
    }

    func cancel() {
        cancelled = true
        worker?.cancel()
    }

    private func startWorker() {
        guard worker == nil, !cancelled else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil }
            while !Task.isCancelled, !self.cancelled,
                  let word = self.buffer.next(finishing: self.finishing) {
                self.reveal(word)
                // Catch up smoothly if the server sends a large burst.
                let delay = self.buffer.pending.count > 1200 ? min(self.interval, 5_000_000)
                    : self.buffer.pending.count > 300 ? min(self.interval, 15_000_000) : self.interval
                do { try await Task.sleep(nanoseconds: delay) }
                catch { return }
            }
        }
    }
}
