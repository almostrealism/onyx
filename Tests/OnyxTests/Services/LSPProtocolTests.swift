import XCTest
@testable import OnyxLib

/// Pure framing tests for LSPProtocol. These lock the trickiest part of the
/// LSP transport — the incremental, banner-tolerant frame parser — without
/// needing a live jdtls. See docs/lsp-code-navigation-plan.md (test strategy).
final class LSPProtocolTests: XCTestCase {

    private func frame(_ json: String) -> Data {
        Data("Content-Length: \(json.utf8.count)\r\n\r\n\(json)".utf8)
    }

    // MARK: encode

    func test_encode_producesContentLengthFrame() {
        let data = LSPProtocol.encode(["jsonrpc": "2.0", "id": 1])!
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("Content-Length: "))
        XCTAssertTrue(text.contains("\r\n\r\n"))
        // Body length in header matches actual body bytes.
        let parts = text.components(separatedBy: "\r\n\r\n")
        let declared = Int(parts[0].replacingOccurrences(of: "Content-Length: ", with: ""))!
        XCTAssertEqual(declared, parts[1].utf8.count)
    }

    func test_encode_roundtripsThroughDecode() {
        var buf = LSPProtocol.encode(["method": "initialized", "value": 42])!
        let msgs = LSPProtocol.decode(&buf)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0]["method"] as? String, "initialized")
        XCTAssertEqual(msgs[0]["value"] as? Int, 42)
        XCTAssertTrue(buf.isEmpty, "fully-consumed buffer should be empty")
    }

    // MARK: decode — completeness

    func test_decode_singleFrame() {
        var buf = frame(#"{"id":7,"result":"ok"}"#)
        let msgs = LSPProtocol.decode(&buf)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0]["id"] as? Int, 7)
    }

    func test_decode_multipleFramesInOneBuffer() {
        var buf = frame(#"{"id":1}"#)
        buf.append(frame(#"{"id":2}"#))
        buf.append(frame(#"{"id":3}"#))
        let msgs = LSPProtocol.decode(&buf)
        XCTAssertEqual(msgs.map { $0["id"] as? Int }, [1, 2, 3])
        XCTAssertTrue(buf.isEmpty)
    }

    func test_decode_partialFrameLeftInBuffer() {
        // A complete frame followed by an incomplete one.
        var buf = frame(#"{"id":1}"#)
        let second = frame(#"{"id":2,"big":"tail"}"#)
        buf.append(second.prefix(second.count - 5))   // chop the last 5 bytes
        let msgs = LSPProtocol.decode(&buf)
        XCTAssertEqual(msgs.count, 1, "only the complete frame decodes")
        XCTAssertEqual(msgs[0]["id"] as? Int, 1)
        XCTAssertFalse(buf.isEmpty, "the partial frame is retained")

        // Deliver the rest; the second frame now completes.
        buf.append(second.suffix(5))
        let more = LSPProtocol.decode(&buf)
        XCTAssertEqual(more.count, 1)
        XCTAssertEqual(more[0]["id"] as? Int, 2)
        XCTAssertTrue(buf.isEmpty)
    }

    func test_decode_headerSplitAcrossReads() {
        let f = frame(#"{"id":9}"#)
        var buf = f.prefix(5)     // "Conte"
        XCTAssertTrue(LSPProtocol.decode(&buf).isEmpty)
        buf.append(f.suffix(f.count - 5))
        let msgs = LSPProtocol.decode(&buf)
        XCTAssertEqual(msgs.first?["id"] as? Int, 9)
    }

    // MARK: decode — banner tolerance

    func test_decode_discardsLeadingBannerNoise() {
        // A hostile login shell printed a MOTD before jdtls's first frame.
        var buf = Data("Welcome to prod-box!\r\nLast login: yesterday\n".utf8)
        buf.append(frame(#"{"id":1,"ok":true}"#))
        let msgs = LSPProtocol.decode(&buf)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0]["id"] as? Int, 1)
    }

    func test_decode_bannerThenTwoFrames() {
        var buf = Data("motd line\n".utf8)
        buf.append(frame(#"{"id":1}"#))
        buf.append(frame(#"{"id":2}"#))
        XCTAssertEqual(LSPProtocol.decode(&buf).map { $0["id"] as? Int }, [1, 2])
    }

    // MARK: decode — robustness

    func test_decode_emptyBufferReturnsNothing() {
        var buf = Data()
        XCTAssertTrue(LSPProtocol.decode(&buf).isEmpty)
    }

    func test_decode_bannerOnlyIsBoundedNotUnbounded() {
        // No header ever arrives; buffer must not grow without bound.
        var buf = Data(repeating: 0x41, count: LSPProtocol.maxBannerBytes + 5000)
        _ = LSPProtocol.decode(&buf)
        XCTAssertLessThan(buf.count, LSPProtocol.maxBannerBytes,
                          "banner-only buffer should be trimmed")
    }

    func test_decode_utf8BodyLengthUsesByteCountNotCharCount() {
        // Multibyte content: Content-Length is bytes, and our framing must
        // honor that (é is 2 UTF-8 bytes).
        let json = #"{"name":"café"}"#
        var buf = frame(json)
        let msgs = LSPProtocol.decode(&buf)
        XCTAssertEqual(msgs.first?["name"] as? String, "café")
        XCTAssertTrue(buf.isEmpty)
    }
}
