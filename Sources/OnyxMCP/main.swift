import Foundation

/// OnyxMCP — stdio-to-socket bridge for MCP integration.
/// Reads JSON-RPC from stdin, forwards to the Onyx app, writes responses to stdout.
///
/// Connection modes:
/// 1. If ONYX_MCP_PORT is set: connect via TCP to 127.0.0.1:<port> (remote SSH forwarding)
/// 2. Otherwise: connect via Unix domain socket (local use)

let socketPath: String = {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent("Onyx/mcp.sock").path
}()

func connectToUnixSocket() -> Int32 {
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

func connectToTCP(port: UInt16) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }

    if result < 0 {
        close(fd)
        return -1
    }
    return fd
}

func connectToOnyx() -> Int32 {
    // Check for TCP port (set by Onyx via SSH -R forwarding)
    if let portStr = ProcessInfo.processInfo.environment["ONYX_MCP_PORT"],
       let port = UInt16(portStr) {
        let fd = connectToTCP(port: port)
        if fd >= 0 {
            FileHandle.standardError.write(Data("OnyxMCP: connected via TCP port \(port)\n".utf8))
            return fd
        }
        FileHandle.standardError.write(Data("OnyxMCP: TCP port \(port) failed, trying Unix socket\n".utf8))
    }

    // Fall back to Unix domain socket (local use)
    let fd = connectToUnixSocket()
    if fd >= 0 {
        FileHandle.standardError.write(Data("OnyxMCP: connected via Unix socket\n".utf8))
    }
    return fd
}

/// Set a receive timeout on a socket (in seconds)
func setReceiveTimeout(fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
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

/// Extract the "id" field from a JSON-RPC request string for error responses
func extractRequestId(_ json: String) -> String {
    // Simple extraction — look for "id": <value>
    if let range = json.range(of: #""id"\s*:\s*"#, options: .regularExpression) {
        let after = json[range.upperBound...]
        // Could be number, string, or null
        if after.hasPrefix("null") { return "null" }
        if after.hasPrefix("\"") {
            if let end = after.dropFirst().firstIndex(of: "\"") {
                return String(after[after.startIndex...end])
            }
        }
        // Number
        let digits = after.prefix(while: { $0.isNumber || $0 == "-" })
        if !digits.isEmpty { return String(digits) }
    }
    return "null"
}

// 30-second timeout for socket reads
let responseTimeout = 30

// Main loop: connect, then read stdin → forward → write stdout
let fd = connectToOnyx()
guard fd >= 0 else {
    FileHandle.standardError.write(Data("OnyxMCP: Cannot connect to Onyx. Is it running?\n".utf8))
    let errorResponse = """
    {"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Cannot connect to Onyx app. Is it running?"}}
    """
    print(errorResponse)
    fflush(stdout)
    exit(1)
}

setReceiveTimeout(fd: fd, seconds: responseTimeout)

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }

    if let response = sendAndReceive(fd: fd, message: line) {
        print(response)
        fflush(stdout)
    } else {
        // Timed out or connection lost — return an error to the caller
        let reqId = extractRequestId(line)
        let errMsg = "Onyx did not respond within \(responseTimeout) seconds. The app may need to be rebuilt with the latest MCP server code."
        FileHandle.standardError.write(Data("OnyxMCP: timeout/error for request\n".utf8))
        print("{\"jsonrpc\":\"2.0\",\"id\":\(reqId),\"error\":{\"code\":-32000,\"message\":\"\(errMsg)\"}}")
        fflush(stdout)
    }
}

close(fd)
