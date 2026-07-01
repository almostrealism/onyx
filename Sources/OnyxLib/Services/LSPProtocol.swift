//
// LSPProtocol.swift
//
// Responsibility: Stateless framing for JSON-RPC over the LSP `Content-Length`
//                 wire format. Encodes messages into frames and incrementally
//                 decodes complete frames out of a byte buffer. Pure — no I/O,
//                 no process, no state beyond the caller-owned buffer.
// Scope: Service. Depends only on Foundation.
//
// Ported and hardened from the jdtls spike's `nextFrame()`. The decoder is
// deliberately tolerant of leading NON-LSP bytes: a remote login shell can
// print an MOTD / profile banner before jdtls emits its first frame, so we
// scan for the `Content-Length:` header rather than assuming a clean stream.
// See spike/README.md finding #2, and docs/lsp-code-navigation-plan.md.
//
// Threading: pure functions / value semantics. The caller (LSPSession) owns
// the buffer and serializes access.
//

import Foundation

public enum LSPProtocol {
    /// Header/body separator per the LSP wire format.
    private static let separator = Data("\r\n\r\n".utf8)
    private static let headerPrefix = Data("Content-Length:".utf8)

    /// Cap on how much leading non-frame junk we retain while hunting for the
    /// first header. Prevents unbounded growth if a host spews banner text.
    static let maxBannerBytes = 1_000_000

    /// Encode a JSON-RPC message (already a Foundation JSON object) into a
    /// `Content-Length`-framed `Data` ready to write to the server's stdin.
    /// Returns nil only if the object isn't serializable.
    public static func encode(_ message: [String: Any]) -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }

    /// Drain every COMPLETE frame from `buffer`, returning the decoded JSON
    /// objects in order. Consumes the bytes it uses (including any leading
    /// banner noise and the frames themselves); leaves a trailing partial
    /// frame in `buffer` for the next call.
    ///
    /// `buffer` is `inout` and caller-owned: append bytes as they arrive off
    /// the pipe, then call `decode` to pull whatever is now complete.
    public static func decode(_ buffer: inout Data) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        while let msg = nextFrame(&buffer) { messages.append(msg) }
        return messages
    }

    /// Extract a single complete frame from the front of `buffer`, or nil if
    /// no complete frame is present yet. On success, removes the consumed
    /// bytes (and any preceding banner noise) from `buffer`.
    static func nextFrame(_ buffer: inout Data) -> [String: Any]? {
        // Find the header. Anything before it is banner noise we discard.
        guard let hRange = buffer.range(of: headerPrefix) else {
            // No header yet: bound retained junk so a chatty host can't OOM us.
            if buffer.count > maxBannerBytes {
                buffer.removeFirst(buffer.count - maxBannerBytes / 10)
            }
            return nil
        }
        if hRange.lowerBound > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<hRange.lowerBound)
        }

        // Need the full header terminator before we can read the length.
        guard let sepRange = buffer.range(of: separator) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<sepRange.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            // Corrupt header bytes — drop the prefix and resync on next header.
            buffer.removeSubrange(buffer.startIndex..<sepRange.upperBound)
            return nil
        }

        var length = -1
        for line in headerStr.components(separatedBy: "\r\n")
        where line.lowercased().hasPrefix("content-length:") {
            let n = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            length = Int(n) ?? -1
        }
        guard length >= 0 else {
            buffer.removeSubrange(buffer.startIndex..<sepRange.upperBound)
            return nil
        }

        // Wait until the whole body has arrived.
        let bodyStart = sepRange.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)

        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}
