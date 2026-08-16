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

@Suite("ProtocolCatalog")
struct ProtocolCatalogTests {

    @Test("SFTP is described with the fields a connection form needs")
    func describesSFTP() throws {
        let descriptor = try #require(ProtocolCatalog.live.descriptor(for: .sftp))

        #expect(descriptor.displayName.contains("SFTP"))
        #expect(descriptor.scheme == "sftp")
        #expect(descriptor.defaultPort == 22)
        #expect(descriptor.fields.contains(.username))
        #expect(descriptor.fields.contains(.password))
        #expect(descriptor.fields.contains(.privateKey))
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
