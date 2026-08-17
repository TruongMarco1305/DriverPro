//
//  PresentationTestSupport.swift
//  DPPresentationTests
//

import DPBookmarks
import DPCore
import DPCredentials
import DPDatabase
import DPServices
import DPTestSupport
import Foundation

/// A prompt that answers instantly, so connecting needs no user.
struct SilentPrompt: UserPrompt {
    var hostKeyDecision: HostKeyDecision = .acceptOnce
    var credentials: Credentials? = .password(username: "duck", password: "hunter2")

    func askHostKey(_ challenge: HostKeyChallenge, for host: RemoteHost) async -> HostKeyDecision {
        hostKeyDecision
    }
    func askCredentials(_ request: CredentialRequest) async -> Credentials? { credentials }
}

/// Hands out one in-memory session, so the whole services graph runs with no server.
struct MemorySessionFactory: SessionFactory {
    let session: MemorySession
    func makeSession(for host: RemoteHost) throws -> any Session { session }
}

enum ServicesFixture {

    static func makeHost(username: String? = "duck") -> RemoteHost {
        RemoteHost(protocolIdentifier: .sftp, hostname: "memory.test", port: 22, username: username)
    }

    /// Services wired to an in-memory database, credential store, and backend.
    ///
    /// Only the backend is substituted — the pool, credential coordinator, and services graph are the
    /// real ones, so what these tests exercise is the presentation layer over genuine plumbing.
    ///
    /// - Parameters:
    ///   - host: The bookmark the backend stands in for. A session reports its own host to the
    ///     delegate, so it must match or credential lookups miss.
    ///   - prompt: How questions are answered.
    ///   - session: An already-seeded backend, if the test needs one.
    static func makeServices(
        for host: RemoteHost,
        prompt: any UserPrompt,
        session: MemorySession? = nil
    ) async throws -> (DriverProServices, MemorySession) {
        let backend = session ?? MemorySession(host: host)

        let services = DriverProServices(
            database: try Database(.memory, migrations: BookmarkStore.migrations),
            credentials: InMemoryCredentialStore(),
            knownHosts: KnownHostsStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "dp-kh-\(UUID().uuidString)")),
            prompt: prompt,
            sessionFactory: MemorySessionFactory(session: backend)
        )
        return (services, backend)
    }
}
