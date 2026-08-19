//
//  CredentialFlowTests.swift
//  DPServicesTests
//

import DPCore
import DPCredentials
import DPTestSupport
import Foundation
import Testing
@testable import DPServices

/// The guarantee this whole step exists for: a saved password means the user is not asked again.
@Suite("Connecting with stored credentials")
struct CredentialFlowTests {

    @Test("A stored password connects without asking the user")
    func storedPasswordSkipsThePrompt() async throws {
        let host = ServicesFixture.makeHost()
        // The prompt fails the test if it is consulted at all.
        let prompt = RecordingPrompt(refusesCredentialPrompt: true)
        let store = InMemoryCredentialStore(passwords: [host.id: "hunter2"])

        let (services, _) = try await ServicesFixture.makeServices(for: host, prompt: prompt, credentials: store)
        try await services.connect(to: host)

        #expect(await prompt.credentialPromptCount == 0)
    }

    @Test("With nothing stored, the user is asked once and the password is saved")
    func firstConnectPromptsThenSaves() async throws {
        let host = ServicesFixture.makeHost()
        let prompt = RecordingPrompt(
            credentials: .password(username: "duck", password: "hunter2", shouldPersist: true)
        )

        let (services, store) = try await ServicesFixture.makeServices(for: host, prompt: prompt)
        try await services.connect(to: host)

        #expect(await prompt.credentialPromptCount == 1)
        #expect(await store.hasPassword(for: host), "an accepted password should have been saved")
    }

    @Test("The second connection uses the saved password")
    func secondConnectUsesTheStore() async throws {
        // The M1 criterion in miniature: connect, quit, connect again without retyping.
        let host = ServicesFixture.makeHost()
        let store = InMemoryCredentialStore()

        let firstPrompt = RecordingPrompt(
            credentials: .password(username: "duck", password: "hunter2", shouldPersist: true)
        )
        let (first, _) = try await ServicesFixture.makeServices(for: host, prompt: firstPrompt, credentials: store)
        try await first.connect(to: host)
        #expect(await firstPrompt.credentialPromptCount == 1)

        // A fresh services graph, as if the app had been relaunched, sharing only the credential store.
        let secondPrompt = RecordingPrompt(refusesCredentialPrompt: true)
        let (second, _) = try await ServicesFixture.makeServices(for: host, prompt: secondPrompt, credentials: store)
        try await second.connect(to: host)

        #expect(await secondPrompt.credentialPromptCount == 0)
    }

    @Test("Declining to save leaves the store empty, and the next connection asks again")
    func notSavingMeansAskingAgain() async throws {
        let host = ServicesFixture.makeHost()
        let store = InMemoryCredentialStore()
        let prompt = RecordingPrompt(
            credentials: .password(username: "duck", password: "hunter2", shouldPersist: false)
        )

        let (services, _) = try await ServicesFixture.makeServices(for: host, prompt: prompt, credentials: store)
        try await services.connect(to: host)

        #expect(await !store.hasPassword(for: host), "the user did not ask for this to be saved")

        let (again, _) = try await ServicesFixture.makeServices(for: host, prompt: prompt, credentials: store)
        try await again.connect(to: host)
        #expect(await prompt.credentialPromptCount == 2)
    }

    @Test("Cancelling the prompt fails the connection rather than hanging")
    func cancellingFailsCleanly() async throws {
        let host = ServicesFixture.makeHost()
        let prompt = RecordingPrompt(credentials: nil)
        let (services, store) = try await ServicesFixture.makeServices(for: host, prompt: prompt)

        await #expect(throws: SessionError.self) {
            try await services.connect(to: host)
        }
        #expect(await !store.hasPassword(for: host))
    }

    @Test("A connection that fails saves nothing")
    func failedConnectionStoresNothing() async throws {
        // Storing an unverified password produces a bookmark that silently fails forever, so a rejected
        // host key must leave the store untouched even though the user asked to save.
        let host = ServicesFixture.makeHost()
        let prompt = RecordingPrompt(
            hostKeyDecision: .reject,
            credentials: .password(username: "duck", password: "hunter2", shouldPersist: true)
        )
        let (services, store) = try await ServicesFixture.makeServices(for: host, prompt: prompt)

        await #expect(throws: SessionError.hostKeyRejected) {
            try await services.connect(to: host)
        }
        #expect(await !store.hasPassword(for: host))
    }

    @Test("An unknown host key reaches the user")
    func hostKeyReachesThePrompt() async throws {
        let host = ServicesFixture.makeHost()
        let prompt = RecordingPrompt(
            credentials: .password(username: "duck", password: "hunter2")
        )
        let (services, _) = try await ServicesFixture.makeServices(for: host, prompt: prompt)

        try await services.connect(to: host)
        #expect(await prompt.hostKeyQuestions.count == 1)
    }

    @Test("withSession reuses the connection rather than reconnecting")
    func withSessionReusesTheConnection() async throws {
        let host = ServicesFixture.makeHost()
        let prompt = RecordingPrompt(
            credentials: .password(username: "duck", password: "hunter2", shouldPersist: true)
        )
        let (services, _) = try await ServicesFixture.makeServices(for: host, prompt: prompt)

        try await services.connect(to: host)
        let listed = try await services.withSession(for: host) { session in
            try await session.list(.root).count
        }

        #expect(listed >= 0)
        // One handshake, so one host key question — the pool did not reconnect.
        #expect(await prompt.hostKeyQuestions.count == 1)
        #expect(await services.pool.connectionCount(for: host) == 1)
    }

    @Test("A bookmark saved and reloaded connects the same way")
    func bookmarkRoundTripThenConnect() async throws {
        // Ties the two halves together: the bookmark comes back from the database, and its password
        // comes back from the credential store, keyed by the same identity.
        let host = ServicesFixture.makeHost()
        let store = InMemoryCredentialStore(passwords: [host.id: "hunter2"])
        let prompt = RecordingPrompt(refusesCredentialPrompt: true)

        let (services, _) = try await ServicesFixture.makeServices(for: host, prompt: prompt, credentials: store)
        try await services.bookmarks.save(host)

        let reloaded = try #require(try await services.bookmarks.load().first)
        #expect(reloaded == host)

        try await services.connect(to: reloaded)
        #expect(await prompt.credentialPromptCount == 0)
    }
}

/// The same guarantee as above, for the other two ways of logging in.
@Suite("Connecting with a key or an agent")
struct KeyAndAgentFlowTests {

    /// A bookmark set to authenticate with the key at `path`.
    private func keyHost(at path: String) -> RemoteHost {
        var host = ServicesFixture.makeHost()
        host.authenticationPreference = .privateKey(path: path)
        return host
    }

    // MARK: - Private key

    @Test("An unencrypted key connects with no prompt at all")
    func unencryptedKeyNeverPrompts() async throws {
        let key = try ServicesFixture.makeKeyFile(encrypted: false)
        defer { try? FileManager.default.removeItem(at: key.deletingLastPathComponent()) }

        let host = keyHost(at: key.path)
        let prompt = RecordingPrompt(refusesCredentialPrompt: true)
        let (services, store) = try await ServicesFixture.makeServices(for: host, prompt: prompt)

        try await services.connect(to: host)

        #expect(await prompt.credentialPromptCount == 0)
        #expect(await store.readCount == 0, "a key connection has no business reading a password")
    }

    @Test("An encrypted key with a stored passphrase connects with no prompt")
    func storedPassphraseSkipsThePrompt() async throws {
        // The private-key twin of "a saved password connects with no prompt at all".
        let key = try ServicesFixture.makeKeyFile(encrypted: true)
        defer { try? FileManager.default.removeItem(at: key.deletingLastPathComponent()) }

        let host = keyHost(at: key.path)
        let prompt = RecordingPrompt(refusesCredentialPrompt: true)
        let store = InMemoryCredentialStore(passphrases: [key.path: "hunter2"])
        let (services, _) = try await ServicesFixture.makeServices(
            for: host, prompt: prompt, credentials: store)

        try await services.connect(to: host)

        #expect(await prompt.credentialPromptCount == 0)
        #expect(await store.passphraseReadCount == 1, "the passphrase came from the store")
    }

    @Test("An encrypted key with no stored passphrase asks for it, and names the key")
    func encryptedKeyPromptsForItsPassphrase() async throws {
        let key = try ServicesFixture.makeKeyFile(encrypted: true)
        defer { try? FileManager.default.removeItem(at: key.deletingLastPathComponent()) }

        let host = keyHost(at: key.path)
        // The sheet has one secret field, so a passphrase comes back in the `.password` case.
        let prompt = RecordingPrompt(
            credentials: .password(username: "duck", password: "hunter2", shouldPersist: true))
        let (services, store) = try await ServicesFixture.makeServices(for: host, prompt: prompt)

        try await services.connect(to: host)

        let asked = try #require(await prompt.credentialQuestions.first)
        guard case .privateKeyPassphrase(let keyPath) = asked.reason else {
            Issue.record("expected a passphrase request, got \(asked.reason)")
            return
        }
        #expect(keyPath == key.path, "the sheet has to say which key it is unlocking")
        #expect(await store.hasPassphrase(forPrivateKeyAt: key.path),
                "an accepted passphrase is saved against the key's path")
        #expect(await !store.hasPassword(for: host), "it was a passphrase, not a password")
    }

    @Test("A passphrase for a connection that failed is not saved")
    func refusedPassphraseIsNotSaved() async throws {
        let key = try ServicesFixture.makeKeyFile(encrypted: true)
        defer { try? FileManager.default.removeItem(at: key.deletingLastPathComponent()) }

        let host = keyHost(at: key.path)
        let prompt = RecordingPrompt(
            hostKeyDecision: .reject,
            credentials: .password(username: "duck", password: "hunter2", shouldPersist: true))
        let (services, store) = try await ServicesFixture.makeServices(for: host, prompt: prompt)

        await #expect(throws: SessionError.hostKeyRejected) {
            try await services.connect(to: host)
        }
        #expect(await !store.hasPassphrase(forPrivateKeyAt: key.path))
    }

    @Test("Cancelling the passphrase prompt fails the connection rather than trying the key anyway")
    func cancellingThePassphraseFails() async throws {
        let key = try ServicesFixture.makeKeyFile(encrypted: true)
        defer { try? FileManager.default.removeItem(at: key.deletingLastPathComponent()) }

        let host = keyHost(at: key.path)
        let (services, _) = try await ServicesFixture.makeServices(
            for: host, prompt: RecordingPrompt(credentials: nil))

        await #expect(throws: SessionError.self) { try await services.connect(to: host) }
    }

    @Test("A key that cannot be read says so, rather than reporting a login failure")
    func unreadableKeyExplainsItself() async throws {
        // The file is gone, moved, or was never a key. Nothing reached the server, so calling this an
        // authentication failure would send the user looking in the wrong place.
        let host = keyHost(at: "/nonexistent-\(UUID().uuidString)/id_ed25519")
        let prompt = RecordingPrompt(
            credentials: .password(username: "duck", password: "hunter2"))
        let (services, _) = try await ServicesFixture.makeServices(for: host, prompt: prompt)

        try await services.connect(to: host)

        let asked = try #require(await prompt.credentialQuestions.first)
        guard case .privateKeyUnreadable(let keyPath, let reason) = asked.reason else {
            Issue.record("expected an unreadable-key request, got \(asked.reason)")
            return
        }
        #expect(keyPath.hasSuffix("id_ed25519"))
        #expect(!reason.isEmpty, "the user needs to be told what is wrong with the file")
    }

    // MARK: - ssh-agent

    @Test("An agent connection asks nothing and reads nothing")
    func agentNeitherPromptsNorReadsTheStore() async throws {
        var host = ServicesFixture.makeHost()
        host.authenticationPreference = .agent

        let prompt = RecordingPrompt(refusesCredentialPrompt: true)
        let store = InMemoryCredentialStore(passwords: [host.id: "hunter2"])
        let (services, _) = try await ServicesFixture.makeServices(
            for: host, prompt: prompt, credentials: store)

        try await services.connect(to: host)

        #expect(await prompt.credentialPromptCount == 0)
        // The agent holds the key. Reaching for a saved password would be both pointless and a way to
        // connect as something other than what the bookmark says.
        #expect(await store.readCount == 0)
    }

    @Test("An agent connection with no user name on the bookmark falls back to the local account")
    func agentFallsBackToTheLocalUsername() async throws {
        // What `ssh host` does when there is no `User` line. There is no prompt in the way to ask.
        var host = ServicesFixture.makeHost(username: nil)
        host.authenticationPreference = .agent

        let coordinator = CredentialCoordinator(
            store: InMemoryCredentialStore(), prompt: RecordingPrompt(refusesCredentialPrompt: true))
        let credentials = await coordinator.session(
            host, needsCredentials: CredentialRequest(host: host, reason: .initial))

        #expect(try #require(credentials).username == NSUserName())
    }
}

@Suite("ProtocolCatalog")
struct ProtocolCatalogTests {

    @Test("SFTP is described with the fields a connection form needs")
    func describesSFTP() throws {
        let descriptor = try #require(ProtocolCatalog.live.descriptor(for: .sftp))

        #expect(descriptor.displayName == "SFTP", "the protocol name alone is enough")
        #expect(!descriptor.iconName.isEmpty, "the sidebar needs an icon per protocol")

        // The chooser draws both for every row, so a missing one is a blank space rather than an error.
        for entry in ProtocolCatalog.live.descriptors {
            #expect(!entry.iconName.isEmpty, "\(entry.displayName) has no icon")
            #expect(!entry.summary.isEmpty, "\(entry.displayName) has no summary")
        }
        #expect(descriptor.scheme == "sftp")
        #expect(descriptor.defaultPort == 22)
        #expect(descriptor.fields.contains(.username))
        #expect(descriptor.fields.contains(.password))
        #expect(descriptor.fields.contains(.privateKey))
    }

    @Test("SFTP advertises all three ways of logging in, password first")
    func advertisesAuthentications() throws {
        let descriptor = try #require(ProtocolCatalog.live.descriptor(for: .sftp))
        #expect(descriptor.authentications == [.password, .privateKey, .agent])
    }

    @Test("Every protocol offers at least one way to log in")
    func everyProtocolCanAuthenticate() {
        // A descriptor with an empty list would render a connection form with no way to prove anything.
        for entry in ProtocolCatalog.live.descriptors {
            #expect(!entry.authentications.isEmpty, "\(entry.displayName) offers no authentication")
        }
    }

    @Test("An unsupported protocol has no descriptor and no default port")
    func unsupportedProtocol() {
        let webdav = ProtocolIdentifier.webdav
        #expect(ProtocolCatalog.live.descriptor(for: webdav) == nil)
        #expect(ProtocolCatalog.live.defaultPort(for: webdav) == nil)
    }

    @Test("The factory builds a session for a supported protocol and refuses others")
    func factoryCoversTheCatalog() throws {
        let factory = ProtocolCatalog.live.makeSessionFactory(
            knownHosts: ServicesFixture.makeThrowawayKnownHosts()
        )

        _ = try factory.makeSession(for: ServicesFixture.makeHost())

        let unsupported = RemoteHost(protocolIdentifier: .s3, hostname: "s3.example.com", port: 443)
        #expect(throws: SessionError.unknownProtocol(.s3)) {
            _ = try factory.makeSession(for: unsupported)
        }
    }
}
