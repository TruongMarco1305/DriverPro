//
//  TransferTestSupport.swift
//  DPTransferTests
//

import DPCore
import DPTestSupport
import Foundation
@testable import DPTransfer

/// A factory handing out one shared `MemorySession`.
///
/// The pool treats each hand-out as a separate connection, but they share storage — which is what a real
/// server does, and what lets a download see the files a test seeded.
struct SharedSessionFactory: SessionFactory {
    let session: MemorySession

    func makeSession(for host: RemoteHost) throws -> any Session { session }
}

/// A factory that counts how many sessions it built, for proving the pool reuses connections.
///
/// A `final class` with a lock rather than an actor, because `makeSession` is synchronous.
final class CountingSessionFactory: SessionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let session: MemorySession
    private var count = 0

    init(session: MemorySession) { self.session = session }

    /// How many sessions have been created.
    var created: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func makeSession(for host: RemoteHost) throws -> any Session {
        lock.lock()
        count += 1
        lock.unlock()
        return session
    }
}

/// A factory that always fails, for the unknown-protocol and connection-failure paths.
struct FailingSessionFactory: SessionFactory {
    func makeSession(for host: RemoteHost) throws -> any Session {
        throw SessionError.unknownProtocol(host.protocolIdentifier)
    }
}

// MARK: - Fixtures

enum TransferFixture {

    static let host = RemoteHost(protocolIdentifier: .sftp, hostname: "memory.test", port: 22)

    /// A connected in-memory session, seeded with a small tree under `/srv`.
    static func makeSession(capabilities: SessionCapabilities = .posixFileSystem) async throws -> MemorySession {
        let session = MemorySession(capabilities: capabilities)
        try await session.connect(credentials: nil, delegate: ScriptedDelegate())
        await session.seed(directory: RemotePath("/srv"))
        return session
    }

    /// A pool over one shared session.
    static func makePool(
        session: MemorySession,
        maxConnectionsPerHost: Int = 4
    ) -> SessionPool {
        SessionPool(
            factory: SharedSessionFactory(session: session),
            delegate: ScriptedDelegate(),
            maxConnectionsPerHost: maxConnectionsPerHost
        )
    }

    /// A fresh empty temporary directory, removed by the caller or left to the OS.
    static func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Deterministic bytes, so a corrupted transfer is detectable rather than merely the wrong length.
    static func bytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }
}
