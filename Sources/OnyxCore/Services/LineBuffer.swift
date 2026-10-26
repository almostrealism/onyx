//
// LineBuffer.swift
//
// Responsibility: Turning streamed text into whole lines. A chunk can end
//                 mid-line; the tail waits for the next chunk instead of
//                 being read as a line of its own.
// Scope: One per stream. Lock-guarded, so a stream's callbacks can arrive
//        on any queue.
//

import Foundation

public final class LineBuffer {
    private var pending = ""
    private let lock = NSLock()

    public init() {}

    /// The complete lines `text` finishes, without their newlines.
    public func append(_ text: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending += text
        guard let lastNewline = pending.lastIndex(of: "\n") else { return [] }
        let complete = pending[..<lastNewline]
        pending = String(pending[pending.index(after: lastNewline)...])
        return complete.components(separatedBy: "\n")
    }
}
