import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct PosixError: Error, CustomStringConvertible {
    public let errno: Int32
    public let op: String
    public init(errno: Int32, op: String) {
        self.errno = errno
        self.op = op
    }
    public var description: String {
        let msg = strerror(errno).flatMap { String(cString: $0) } ?? "unknown"
        return "\(op) failed: errno=\(errno) (\(msg))"
    }
}

/// Minimal listener for a Unix Domain Socket. Server side — accepts ONE incoming connection.
/// (QVAC's worker is single-connection per RPC instance.)
public final class PosixUDSListener {
    public let path: String
    private let listenFD: Int32

    public init(path: String, backlog: Int32 = 1) throws {
        self.path = path
        // Best-effort remove pre-existing socket file
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PosixError(errno: errno, op: "socket") }
        self.listenFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxLen else {
            Darwin.close(fd)
            throw PosixError(errno: ENAMETOOLONG, op: "uds-path-too-long(\(pathBytes.count) > \(maxLen))")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            for (i, b) in pathBytes.enumerated() { rawBuf[i] = b }
            rawBuf[pathBytes.count] = 0
        }

        let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRC == 0 else {
            let e = errno; Darwin.close(fd); throw PosixError(errno: e, op: "bind")
        }

        guard listen(fd, backlog) == 0 else {
            let e = errno; Darwin.close(fd); throw PosixError(errno: e, op: "listen")
        }
    }

    /// Blocks until a client connects. Returns the connected fd.
    public func accept(timeoutMs: Int = 30_000) throws -> Int32 {
        // Use poll(2) so we can time out cleanly.
        var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        let rc = withUnsafeMutablePointer(to: &pfd) { p in
            poll(p, 1, Int32(timeoutMs))
        }
        if rc == 0 {
            throw PosixError(errno: ETIMEDOUT, op: "accept-timeout(\(timeoutMs)ms)")
        }
        if rc < 0 {
            throw PosixError(errno: errno, op: "poll")
        }
        var clientAddr = sockaddr_un()
        var len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connFD = withUnsafeMutablePointer(to: &clientAddr) { ap -> Int32 in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                #if canImport(Darwin)
                return Darwin.accept(listenFD, sa, &len)
                #else
                return Glibc.accept(listenFD, sa, &len)
                #endif
            }
        }
        guard connFD >= 0 else { throw PosixError(errno: errno, op: "accept") }
        return connFD
    }

    public func close() {
        #if canImport(Darwin)
        _ = Darwin.close(listenFD)
        #else
        _ = Glibc.close(listenFD)
        #endif
        unlink(path)
    }

    deinit { close() }
}

/// Helpers for blocking read/write on a connected fd.
public enum PosixIO {
    public static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = data.count
            var ptr = base
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw PosixError(errno: errno, op: "write")
                }
                if n == 0 { throw PosixError(errno: EPIPE, op: "write-zero") }
                remaining -= n
                ptr = ptr.advanced(by: n)
            }
        }
    }

    /// Wait for fd readability with timeout. Returns true if readable, false on timeout.
    public static func waitReadable(fd: Int32, timeoutMs: Int) throws -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let rc = withUnsafeMutablePointer(to: &pfd) { p in poll(p, 1, Int32(timeoutMs)) }
        if rc == 0 { return false }
        if rc < 0 {
            if errno == EINTR { return false }
            throw PosixError(errno: errno, op: "poll")
        }
        return (pfd.revents & Int16(POLLIN)) != 0
    }

    /// Read up to `cap` bytes; returns empty Data on EOF or read-would-block-but-EOF.
    public static func readSome(fd: Int32, cap: Int = 64 * 1024) throws -> Data {
        var buf = [UInt8](repeating: 0, count: cap)
        let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
            #if canImport(Darwin)
            return Darwin.read(fd, bp.baseAddress, bp.count)
            #else
            return Glibc.read(fd, bp.baseAddress, bp.count)
            #endif
        }
        if n < 0 {
            if errno == EINTR { return Data() }
            throw PosixError(errno: errno, op: "read")
        }
        if n == 0 { return Data() }
        return Data(buf.prefix(n))
    }
}
