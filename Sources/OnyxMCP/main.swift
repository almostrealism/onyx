import Foundation
#if canImport(Network)
import Network
#endif

/// OnyxMCP — stdio-to-socket bridge for Claude Code MCP integration.
/// Reads JSON-RPC from stdin, forwards to the Onyx app via Unix domain socket,
/// and writes responses to stdout.

let socketPath: String = {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent("Onyx/mcp.sock").path
}()

func connectToSocket() -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return -1 }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
            for (i, byte) in pathBytes.enumerated() {
                dest[i] = byte
            }
        }
    }

    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    if result < 0 {
        close(fd)
        return -1
    }
    return fd
}

func sendAndReceive(fd: Int32, message: String) -> String? {
    let data = message + "\n"
    guard data.withCString({ ptr in write(fd, ptr, strlen(ptr)) }) > 0 else { return nil }

    var buffer = [UInt8](repeating: 0, count: 1_000_000)
    let bytesRead = read(fd, &buffer, buffer.count - 1)
    guard bytesRead > 0 else { return nil }
    return String(bytes: buffer[0..<bytesRead], encoding: .utf8)?
        .trimmingCharacters(in: .newlines)
}

// Main loop: read stdin line by line, forward to socket, write response to stdout
let fd = connectToSocket()
guard fd >= 0 else {
    let errorResponse = """
    {"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Cannot connect to Onyx app. Is it running?"}}
    """
    FileHandle.standardError.write(Data((errorResponse + "\n").utf8))
    exit(1)
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }

    if let response = sendAndReceive(fd: fd, message: line) {
        print(response)
        fflush(stdout)
    }
}

close(fd)
