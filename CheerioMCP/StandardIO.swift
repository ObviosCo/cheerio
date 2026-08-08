import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Newline-delimited JSON over stdin and stdout — the transport half of the MCP
/// helper, and the only part of it that touches a file descriptor.
///
/// Two rules govern everything here. **Nothing but protocol messages may reach
/// stdout**: an MCP client parses that stream, so one stray `print` desynchronizes the
/// session, which is why diagnostics go to stderr via ``StandardIO/note(_:)``. And
/// **`read` and `write` are looped**: a pipe hands over as much as it feels like, so a
/// single `read` can split a JSON-RPC message in half and a single `write` can place
/// part of a response, and treating either as complete is the classic way a stdio
/// server corrupts its own framing.
enum StandardIO {
    /// Yields one complete line at a time, ending when the client closes the pipe.
    ///
    /// Not an `AsyncStream`: the read is blocking and this process has nothing else to
    /// do while it waits, so a thread hop per message would buy nothing and add a way
    /// for output to arrive out of order.
    static func lines() -> AnyIterator<Data> {
        var buffer = Data()
        var atEOF = false
        return AnyIterator {
            while true {
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    // Blank lines and \r\n framing: both are the client's business, not
                    // something to fail a session over.
                    let trimmed = Data(line.filter { $0 != UInt8(ascii: "\r") })
                    if trimmed.isEmpty { continue }
                    return trimmed
                }
                if atEOF {
                    // A last line with no trailing newline still counts.
                    guard !buffer.isEmpty else { return nil }
                    let remainder = buffer
                    buffer.removeAll()
                    return remainder
                }
                guard let chunk = readChunk(), !chunk.isEmpty else {
                    atEOF = true
                    continue
                }
                buffer.append(chunk)
            }
        }
    }

    /// Writes one message and its newline, retrying until the whole thing is out.
    static func writeLine(_ data: Data) {
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(STDOUT_FILENO, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                // EINTR is a signal, not a failure. Anything else means the client has
                // gone: there is nowhere left to report it, so stop.
                if written < 0 && errno == EINTR { continue }
                return
            }
        }
    }

    /// Diagnostics, on stderr, where they can't be mistaken for protocol.
    static func note(_ message: String) {
        FileHandle.standardError.write(Data("cheerio-mcp: \(message)\n".utf8))
    }

    private static func readChunk() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            if count > 0 { return Data(bytes[0..<count]) }
            if count == 0 { return Data() }
            if errno == EINTR { continue }
            return nil
        }
    }
}
