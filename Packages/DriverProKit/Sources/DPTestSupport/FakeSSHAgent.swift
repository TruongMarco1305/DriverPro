//
//  FakeSSHAgent.swift
//  DPTestSupport
//

import DPCredentials
import Darwin
import Foundation

// MARK: - Canned replies

/// An ``SSHAgentTransport`` that answers from a script, with no socket involved.
///
/// For testing everything above the socket: message construction, reply parsing, and the offer chain that
/// consumes identities. Lives here rather than in one test target because both `DPCredentialsTests` and
/// `DPProtocolSFTPTests` need an agent that behaves predictably.
public struct StubAgentTransport: SSHAgentTransport {

    /// Replies to hand out, in order. The last one repeats once the list is used up, so a test that signs
    /// several times does not have to say so.
    private let replies: [Data]

    /// An error to throw instead of replying.
    private let failure: (any Error)?

    /// Records every request made, so a test can assert what went on the wire.
    private let recorder = Recorder()

    /// Creates a transport that replies with the given payloads.
    /// - Parameter replies: Unframed reply payloads — message number first, then contents.
    public init(replies: [Data]) {
        self.replies = replies
        self.failure = nil
    }

    /// Creates a transport that always throws.
    /// - Parameter failure: What to throw.
    public init(failure: any Error) {
        self.replies = []
        self.failure = failure
    }

    /// Every request sent through this transport, framed exactly as it went out.
    public var requests: [Data] { recorder.requests }

    /// Records the request and hands back the next scripted reply.
    ///
    /// - Parameter request: The framed request, kept in ``requests``.
    /// - Returns: The next reply, or the last one again once the script runs out.
    /// - Throws: Whatever this transport was built to throw.
    public func exchange(_ request: Data) throws -> Data {
        if let failure { throw failure }
        let index = recorder.record(request)
        guard !replies.isEmpty else {
            throw CredentialError.agent(reason: "the stub has no reply configured")
        }
        return replies[min(index, replies.count - 1)]
    }

    /// A lock-guarded log. The transport is a `struct`, so the recording has to live behind a reference.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Data] = []

        var requests: [Data] { lock.withLock { storage } }

        /// Appends a request and returns how many came before it.
        func record(_ request: Data) -> Int {
            lock.withLock {
                storage.append(request)
                return storage.count - 1
            }
        }
    }
}

// MARK: - A real socket

/// An ssh-agent impersonator listening on a real Unix domain socket.
///
/// This exists to test ``UnixSocketAgentTransport`` itself — the `sockaddr_un` handling, the timeouts, and
/// the short-read loop. Those are the parts that cannot be exercised through ``StubAgentTransport``, and
/// they are also the parts most likely to be wrong.
///
/// The socket path is kept short deliberately. `sockaddr_un.sun_path` holds 104 bytes on Darwin and a
/// longer path is **silently truncated**, so a test using a long temporary directory would fail with
/// "no such file" for a socket sitting right there. ``socketPath`` is asserted to fit.
public final class FakeSSHAgent: @unchecked Sendable {

    /// How to answer one request.
    public enum Behaviour: Sendable {
        /// Reply with these unframed payloads, in order, framing each one.
        case replies([Data])
        /// Accept the connection and then say nothing, so the client's receive timeout fires.
        case silence
        /// Accept the connection and close it at once, mid-message.
        case hangUp
    }

    /// Where the agent is listening. Pass this to ``UnixSocketAgentTransport``.
    public let socketPath: String

    private let behaviour: Behaviour
    private let listener: Int32
    private let served = Counter()

    /// Starts listening.
    ///
    /// - Parameter behaviour: How to answer.
    /// - Throws: If the socket cannot be created or bound.
    public init(behaviour: Behaviour) throws {
        self.behaviour = behaviour

        // Short by construction: a UUID would already be 36 characters before the directory.
        let name = String(UInt32.random(in: 0..<UInt32.max), radix: 16)
        self.socketPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("dp-\(name).sock")
        guard socketPath.utf8.count < 104 else {
            throw CredentialError.agent(reason: "test socket path is too long: \(socketPath)")
        }
        unlink(socketPath)

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw CredentialError.agent(reason: "could not open a listening socket (\(errno))")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: Array(socketPath.utf8))
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(listener, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 4) == 0 else {
            let failure = errno
            close(listener)
            throw CredentialError.agent(reason: "could not bind \(socketPath) (\(failure))")
        }

        Thread.detachNewThread { [self] in serve() }
    }

    /// Stops listening and removes the socket file.
    public func stop() {
        close(listener)
        unlink(socketPath)
    }

    /// How many requests have been answered.
    public var requestsServed: Int { served.value }

    // MARK: - Serving

    /// Accepts connections until the listener is closed.
    ///
    /// One connection per exchange, matching what ``UnixSocketAgentTransport`` does — it opens a socket
    /// per request rather than pooling one.
    private func serve() {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }         // the listener was closed: we are done
            defer { close(connection) }

            // Without this, writing to a client that has already gone raises SIGPIPE, whose default
            // disposition kills the process — taking the test runner with it. Same reason
            // `UnixSocketAgentTransport` sets it.
            var enabled: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                       socklen_t(MemoryLayout<Int32>.size))

            switch behaviour {
            case .hangUp:
                served.increment()

            case .silence:
                served.increment()
                // Hold the connection open without writing, so the client waits for its timeout. Long
                // enough to outlast any timeout a test would sensibly set.
                Thread.sleep(forTimeInterval: 5)

            case .replies(let replies):
                guard readRequest(from: connection) != nil else { continue }
                let index = served.increment()
                guard !replies.isEmpty else { continue }
                let reply = SSHAgentWireFraming.framed(replies[min(index, replies.count - 1)])
                _ = Array(reply).withUnsafeBufferPointer { buffer in
                    write(connection, buffer.baseAddress, buffer.count)
                }
            }
        }
    }

    /// Reads one length-prefixed request, or `nil` if the client went away.
    private func readRequest(from connection: Int32) -> Data? {
        var header = [UInt8](repeating: 0, count: 4)
        guard read(connection, &header, 4) == 4 else { return nil }

        let length = header.reduce(into: UInt32(0)) { $0 = ($0 << 8) | UInt32($1) }
        guard length > 0, length < 64 * 1_024 else { return nil }

        var payload = [UInt8](repeating: 0, count: Int(length))
        var filled = 0
        while filled < payload.count {
            let received = payload[filled...].withUnsafeMutableBufferPointer { slice in
                read(connection, slice.baseAddress, slice.count)
            }
            guard received > 0 else { return nil }
            filled += received
        }
        return Data(payload)
    }

    /// A lock-guarded count, incremented from the serving thread and read from the test's.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int { lock.withLock { storage } }

        /// Increments and returns the value from *before* the increment.
        @discardableResult
        func increment() -> Int {
            lock.withLock {
                defer { storage += 1 }
                return storage
            }
        }
    }
}

// MARK: - Framing

/// The one piece of the agent wire format this target needs: the 4-byte big-endian length prefix.
///
/// Duplicated rather than exposed from `DPCredentials`, which keeps `SSHAgentWire` internal. Two lines is
/// a smaller price than widening a production type's visibility to suit a test double.
public enum SSHAgentWireFraming {

    /// Wraps a payload in its length prefix.
    /// - Parameter payload: The message contents.
    public static func framed(_ payload: Data) -> Data {
        let count = UInt32(payload.count)
        var message = Data([
            UInt8(truncatingIfNeeded: count >> 24),
            UInt8(truncatingIfNeeded: count >> 16),
            UInt8(truncatingIfNeeded: count >> 8),
            UInt8(truncatingIfNeeded: count),
        ])
        message.append(payload)
        return message
    }
}
