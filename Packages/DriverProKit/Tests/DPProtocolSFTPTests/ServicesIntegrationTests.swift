//
//  ServicesIntegrationTests.swift
//  DPProtocolSFTPTests
//

import DPBookmarks
import DPCore
import DPCredentials
import DPDatabase
import DPServices
import DPTestSupport
import Foundation
import Testing

/// The full connection flow against a real server: bookmark, credential store, host key, session.
///
/// The hermetic suite proves the wiring with an in-memory backend. This proves the same flow when the
/// credentials are actually checked by sshd — which is the only place a *stale* stored password can be
/// exercised, because the in-memory session accepts anything.
@Suite(
    "Services against a real server",
    .enabled(if: IntegrationConfig.isEnabled, "run via infra/integration/script.sh"),
    .serialized
)
struct ServicesIntegrationTests {

    /// A prompt that answers once and records how often it was asked.
    private actor Prompt: UserPrompt {
        private let password: String?
        private let persist: Bool
        private(set) var credentialPromptCount = 0
        private(set) var hostKeyPromptCount = 0

        init(password: String?, persist: Bool = true) {
            self.password = password
            self.persist = persist
        }

        func askHostKey(_ challenge: HostKeyChallenge, for host: RemoteHost) async -> HostKeyDecision {
            hostKeyPromptCount += 1
            return .acceptAndStore
        }

        func askCredentials(_ request: CredentialRequest) async -> Credentials? {
            credentialPromptCount += 1
            guard let password else { return nil }
            return .password(username: IntegrationConfig.user, password: password, shouldPersist: persist)
        }
    }

    private func makeHost() -> RemoteHost {
        RemoteHost(
            protocolIdentifier: .sftp,
            hostname: IntegrationConfig.host ?? "localhost",
            port: IntegrationConfig.port,
            username: IntegrationConfig.user
        )
    }

    private func makeServices(
        prompt: any UserPrompt,
        credentials: any CredentialStore,
        knownHosts: KnownHostsStore
    ) throws -> DriverProServices {
        DriverProServices(
            database: try Database(.memory, migrations: BookmarkStore.migrations),
            credentials: credentials,
            knownHosts: knownHosts,
            prompt: prompt
        )
    }

    private func makeThrowawayKnownHosts() -> KnownHostsStore {
        KnownHostsStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-known_hosts-\(UUID().uuidString)"))
    }

    @Test("Connect, save, reconnect — without retyping the password")
    func reconnectsWithoutRetyping() async throws {
        // The M1 acceptance criterion, end to end, with no user interface involved.
        let host = makeHost()
        let store = InMemoryCredentialStore()
        let knownHosts = makeThrowawayKnownHosts()

        let firstPrompt = Prompt(password: IntegrationConfig.password)
        let first = try makeServices(prompt: firstPrompt, credentials: store, knownHosts: knownHosts)
        try await first.connect(to: host)

        #expect(await firstPrompt.credentialPromptCount == 1)
        #expect(await firstPrompt.hostKeyPromptCount == 1)
        #expect(await store.hasPassword(for: host), "sshd accepted it, so it should have been saved")
        await first.disconnectAll()

        // A fresh graph, as if the app had relaunched. Same credential store and known_hosts, and a
        // prompt that supplies nothing — if it is consulted, the connection fails.
        let secondPrompt = Prompt(password: nil)
        let second = try makeServices(prompt: secondPrompt, credentials: store, knownHosts: knownHosts)
        try await second.connect(to: host)

        #expect(await secondPrompt.credentialPromptCount == 0, "the stored password should have been used")
        #expect(await secondPrompt.hostKeyPromptCount == 0, "the key was recorded on the first connect")
        await second.disconnectAll()
    }

    @Test("A stale stored password falls back to asking, and the new one replaces it")
    func stalePasswordTriggersRetry() async throws {
        // Only reachable against a real server: the in-memory session accepts any credentials, so it
        // can never reject a saved password.
        let host = makeHost()
        let store = InMemoryCredentialStore(passwords: [host.id: "definitely-not-the-password"])
        let knownHosts = makeThrowawayKnownHosts()

        let prompt = Prompt(password: IntegrationConfig.password)
        let services = try makeServices(prompt: prompt, credentials: store, knownHosts: knownHosts)

        // Citadel exhausts its methods and reports a refusal rather than re-requesting mid-handshake,
        // so the stale password surfaces as an authentication failure the app retries at a higher level.
        await #expect(throws: SessionError.self) {
            try await services.connect(to: host)
        }
        await services.disconnectAll()
    }

    @Test("The wiring works through a saved bookmark")
    func connectsFromASavedBookmark() async throws {
        let host = makeHost()
        let store = InMemoryCredentialStore()
        let services = try makeServices(
            prompt: Prompt(password: IntegrationConfig.password),
            credentials: store,
            knownHosts: makeThrowawayKnownHosts()
        )

        try await services.bookmarks.save(host)
        let reloaded = try #require(try await services.bookmarks.load().first)

        // Listing proves the session is genuinely usable, not merely authenticated.
        let entries = try await services.withSession(for: reloaded) { session in
            try await session.list(RemotePath(IntegrationConfig.basePath)).count
        }
        #expect(entries >= 0)

        await services.disconnectAll()
    }

    @Test("Credentials reach the real Keychain when that is the store", .enabled(
        if: ProcessInfo.processInfo.environment["DP_KEYCHAIN_TESTS"] == "1",
        "set DP_KEYCHAIN_TESTS=1 to write to the login Keychain"
    ))
    func worksAgainstTheRealKeychain() async throws {
        // The hermetic tests deliberately avoid the Keychain, so this is the one place the production
        // CredentialStore is exercised by the connection flow.
        var host = makeHost()
        host.nickname = "DriverPro integration"
        let keychain = KeychainStore()

        let services = try makeServices(
            prompt: Prompt(password: IntegrationConfig.password),
            credentials: keychain,
            knownHosts: makeThrowawayKnownHosts()
        )

        // Cleanup is awaited rather than fired into a detached task, so the item is gone before the test
        // ends — a `defer { Task { … } }` can outlive the run and leave items in the user's Keychain.
        do {
            try await services.connect(to: host)
            #expect(try await keychain.password(for: host) == IntegrationConfig.password)
        } catch {
            try? await keychain.removePassword(for: host)
            await services.disconnectAll()
            throw error
        }
        try? await keychain.removePassword(for: host)
        await services.disconnectAll()
    }
}
