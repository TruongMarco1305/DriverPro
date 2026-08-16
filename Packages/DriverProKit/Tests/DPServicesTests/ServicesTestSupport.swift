//
//  ServicesTestSupport.swift
//  DPServicesTests
//

import DPBookmarks
import DPCore
import DPCredentials
import DPDatabase
import DPTestSupport
import Foundation
import Testing
@testable import DPServices

/// A prompt that answers from a script and records every question it was asked.
///
/// The recording is the point. "Did the user get asked for a password?" is the guarantee this whole
/// step exists to provide, and counting calls is how it becomes assertable.
actor RecordingPrompt: UserPrompt {

    /// What to answer host key challenges with.
    private let hostKeyDecision: HostKeyDecision
    /// What to answer credential requests with, or `nil` to simulate cancelling.
    private let credentials: Credentials?
    /// When true, being asked for credentials is a test failure. Host key questions stay allowed:
    /// a first connection to an unknown server legitimately asks about the key.
    private let refusesCredentialPrompt: Bool

    private(set) var hostKeyQuestions: [HostKeyChallenge] = []
    private(set) var credentialQuestions: [CredentialRequest] = []

    init(
        hostKeyDecision: HostKeyDecision = .acceptOnce,
        credentials: Credentials? = nil,
        refusesCredentialPrompt: Bool = false
    ) {
        self.hostKeyDecision = hostKeyDecision
        self.credentials = credentials
        self.refusesCredentialPrompt = refusesCredentialPrompt
    }

    /// How many times credentials were requested.
    var credentialPromptCount: Int { credentialQuestions.count }

    func askHostKey(_ challenge: HostKeyChallenge, for host: RemoteHost) async -> HostKeyDecision {
        hostKeyQuestions.append(challenge)
        return hostKeyDecision
    }

    func askCredentials(_ request: CredentialRequest) async -> Credentials? {
        credentialQuestions.append(request)
        if refusesCredentialPrompt {
            Issue.record("the user was asked for credentials that should have come from the store")
        }
        return credentials
    }
}

// MARK: - Fixtures

enum ServicesFixture {

    static func makeHost(username: String? = "duck") -> RemoteHost {
        RemoteHost(protocolIdentifier: .sftp, hostname: "memory.test", port: 22, username: username)
    }

    /// Services wired to an in-memory database, credential store, and backend.
    ///
    /// Only the *backend* is substituted. `SessionPool`, `CredentialCoordinator` and
    /// `DriverProServices` are the real ones, so what these tests exercise is the wiring — which
    /// questions get asked, and what gets saved — without needing a server.
    static func makeServices(
        for host: RemoteHost,
        prompt: any UserPrompt,
        credentials: InMemoryCredentialStore = InMemoryCredentialStore()
    ) async throws -> (DriverProServices, InMemoryCredentialStore) {
        let database = try Database(.memory, migrations: BookmarkStore.migrations)
        // Built with the bookmark it stands in for: a session reports its own host to the delegate, and
        // the credential store is keyed by that identity.
        let backend = MemorySession(host: host)

        let services = DriverProServices(
            database: database,
            credentials: credentials,
            knownHosts: makeThrowawayKnownHosts(),
            prompt: prompt,
            sessionFactory: MemorySessionFactory(session: backend)
        )
        return (services, credentials)
    }

    static func makeThrowawayKnownHosts() -> KnownHostsStore {
        KnownHostsStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-known_hosts-\(UUID().uuidString)"))
    }
}

/// A factory producing `MemorySession`s, so the services graph can be exercised without a server.
struct MemorySessionFactory: SessionFactory {
    let session: MemorySession

    func makeSession(for host: RemoteHost) throws -> any Session { session }
}
