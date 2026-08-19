//
//  SSHAgentTransport.swift
//  DPCredentials
//

import Darwin
import Foundation

/// One request/response exchange with an ssh-agent.
///
/// A seam, for two reasons. Tests get to answer with canned bytes instead of needing a running agent —
/// and it names the one thing this whole design turns on, which is that an exchange is **synchronous**.
/// See ``SSHAgentClient`` for why it has to be.
public protocol SSHAgentTransport: Sendable {

    /// Sends one already-framed request and returns the reply, with its length prefix removed.
    ///
    /// - Parameter request: A complete framed message from ``SSHAgentWire``.
    /// - Returns: The reply payload: message number first, then its contents.
    /// - Throws: ``CredentialError/agent(reason:)`` if the agent cannot be reached or does not answer.
    func exchange(_ request: Data) throws -> Data
}

/// Talks to an ssh-agent over a Unix domain socket.
///
/// ## Swift note — POSIX sockets from Swift
/// This is `docs/swift-notes.md` §18 ("Calling C from Swift") again, but with a wrinkle SQLite does not
/// have: `sockaddr_un` is a C struct with a fixed-size character array in it, and Swift has no way to
/// write one directly. The dance below — fill the array byte by byte, then `withUnsafePointer` and
/// `withMemoryRebound` to view it as the `sockaddr` that `connect` wants — is the standard way, and it
/// is ugly in every language that is not C.
///
/// Three details that are easy to get wrong and hard to debug:
///
/// - **`sun_path` holds 104 bytes on Darwin.** A longer path is silently truncated, and you get
///   `ENOENT` for a socket that plainly exists. Checked explicitly here.
/// - **A fresh connection per exchange.** No pooled descriptor, so no shared mutable state, so no lock
///   and no chance of two threads interleaving on one socket. `ssh` itself reconnects per operation.
/// - **`read` must loop.** A stream socket may return fewer bytes than asked for, and a reply arriving
///   in two pieces is not an error. Trusting one `read` is the bug that only shows up under load.
public struct UnixSocketAgentTransport: SSHAgentTransport {

    /// Where the agent is listening.
    public let socketPath: String

    /// How long to wait on a send or a receive.
    ///
    /// Generous on purpose. A hardware-backed agent — Secretive, a YubiKey, 1Password — may be sitting on
    /// a Touch ID prompt, and a human takes seconds. Short enough that a dead agent does not look like a
    /// hung app.
    public let timeout: TimeInterval

    /// The largest reply that will be read.
    ///
    /// A length field is data from outside the process; without a ceiling, an agent claiming a 4 GB reply
    /// would be allowed to ask for 4 GB. An identity list of any plausible size is a few kilobytes.
    private static let maximumReplySize = 256 * 1_024

    /// Creates a transport.
    ///
    /// - Parameters:
    ///   - socketPath: Path to the agent's socket, normally `$SSH_AUTH_SOCK`.
    ///   - timeout: Send and receive timeout. Defaults to 20 seconds.
    public init(socketPath: String, timeout: TimeInterval = 20) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    // MARK: - Exchange

    /// Opens a socket, sends the request, reads the reply, and closes.
    ///
    /// - Parameter request: A complete framed message.
    /// - Returns: The reply payload with its length prefix removed.
    /// - Throws: ``CredentialError/agent(reason:)`` if the socket cannot be opened or trusted, the agent
    ///   hangs up, or the timeout expires.
    public func exchange(_ request: Data) throws -> Data {
        let descriptor = try connect()
        defer { close(descriptor) }

        try writeAll(request, to: descriptor)

        // The reply's own length prefix says how much more to read, so it is read in two steps rather
        // than guessing at a buffer size.
        let header = try readExactly(4, from: descriptor)
        var reader = ByteReader(header)
        guard let length = reader.readUInt32(), length > 0, length <= Self.maximumReplySize else {
            throw CredentialError.agent(reason: "the agent announced an implausible reply size")
        }
        return try readExactly(Int(length), from: descriptor)
    }

    // MARK: - Socket

    /// Opens and connects a socket to the agent, after checking the socket is one we should trust.
    private func connect() throws -> Int32 {
        try verifyOwnership()

        // `sun_path` is a fixed 104-byte array on Darwin. Longer paths do not fail loudly — they are
        // truncated, and then `connect` reports a missing file for a socket that is right there.
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw CredentialError.agent(reason: "the agent's socket path is too long for a Unix socket")
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CredentialError.agent(reason: "could not open a socket (\(errno))")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let failure = errno
            close(descriptor)
            throw CredentialError.agent(
                reason: "could not reach the ssh-agent at \(socketPath) (\(String(cString: strerror(failure)))")
        }

        configure(descriptor)
        return descriptor
    }

    /// Refuses a socket that is not a socket, or that somebody else owns.
    ///
    /// `SSH_AUTH_SOCK` is an environment variable, and anything that can set the environment can point it
    /// at a socket it controls — which would then be asked to sign, and would learn what we are trying to
    /// authenticate to. Checking the type and the owner costs one `stat` and closes that door. The app is
    /// not sandboxed (ADR 004), so there is no other gate in the way.
    private func verifyOwnership() throws {
        var info = stat()
        guard stat(socketPath, &info) == 0 else {
            throw CredentialError.agent(reason: "there is no ssh-agent socket at \(socketPath)")
        }
        guard info.st_mode & S_IFMT == S_IFSOCK else {
            throw CredentialError.agent(reason: "\(socketPath) is not a socket")
        }
        guard info.st_uid == getuid() else {
            throw CredentialError.agent(reason: "the socket at \(socketPath) belongs to another user")
        }
    }

    /// Applies the timeouts, and stops a vanished agent from killing the process.
    ///
    /// `SO_NOSIGPIPE` is not an optimisation. By default, writing to a socket whose other end has closed
    /// raises `SIGPIPE`, and the default disposition for `SIGPIPE` is to **terminate the process** — so an
    /// agent that quit between one exchange and the next would take the whole app down rather than
    /// producing an error. With this set, the same `write` returns `EPIPE` and becomes an ordinary throw.
    /// (Found by the `hangUp` test, which killed the test runner with signal 13 before this existed.)
    ///
    /// Failure of the timeout options is ignored: a socket without them still works, and refusing to talk
    /// to the agent because `setsockopt` was unhappy would trade a small risk for a certain failure.
    private func configure(_ descriptor: Int32) {
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))

        let whole = Int(timeout)
        var value = timeval(
            tv_sec: whole,
            tv_usec: suseconds_t((timeout - Double(whole)) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, size)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, size)
    }

    // MARK: - Reading and writing

    /// Writes every byte, looping over short writes.
    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var sent = 0
        let bytes = Array(data)

        while sent < bytes.count {
            let written = bytes[sent...].withUnsafeBufferPointer { buffer in
                write(descriptor, buffer.baseAddress, buffer.count)
            }
            guard written > 0 else {
                throw CredentialError.agent(reason: "the connection to the ssh-agent closed while sending")
            }
            sent += written
        }
    }

    /// Reads exactly `count` bytes, looping over short reads.
    private func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0

        while filled < count {
            let received = buffer[filled...].withUnsafeMutableBufferPointer { slice in
                read(descriptor, slice.baseAddress, slice.count)
            }
            guard received > 0 else {
                // Zero is a clean close mid-message; negative with `EAGAIN` is the timeout expiring.
                throw CredentialError.agent(reason: received == 0
                    ? "the ssh-agent closed the connection early"
                    : "the ssh-agent did not answer in time")
            }
            filled += received
        }
        return Data(buffer)
    }
}
