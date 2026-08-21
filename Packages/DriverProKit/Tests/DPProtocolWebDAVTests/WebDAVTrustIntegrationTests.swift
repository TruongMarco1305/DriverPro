//
//  WebDAVTrustIntegrationTests.swift
//  DPProtocolWebDAVTests
//

import DPCore
import DPCredentials
import DPTestSupport
import Foundation
import Testing
@testable import DPProtocolWebDAV

/// Where the TLS endpoint is, when there is one.
enum WebDAVTLSConfig {
    static let port = Int(ProcessInfo.processInfo.environment["WEBDAV_TLS_PORT"] ?? "") ?? 8443
    static var isEnabled: Bool { WebDAVIntegrationConfig.isEnabled }
}

/// A delegate that answers the certificate question with a fixed answer, and counts the asking.
///
/// Counting is the point of several of these tests: "asks once" and "never asks again" are the whole
/// behaviour, and neither can be observed from the outcome alone.
private actor CountingTrustDelegate: SessionDelegate {

    private let answer: CertificateDecision
    private(set) var questionCount = 0
    private(set) var lastChallenge: CertificateChallenge?

    init(answer: CertificateDecision) {
        self.answer = answer
    }

    func session(
        _ host: RemoteHost,
        needsCertificateVerification challenge: CertificateChallenge
    ) async -> CertificateDecision {
        questionCount += 1
        lastChallenge = challenge
        return answer
    }

    func session(_ host: RemoteHost, needsHostKeyVerification challenge: HostKeyChallenge) async -> HostKeyDecision {
        .reject
    }

    func session(_ host: RemoteHost, needsCredentials request: CredentialRequest) async -> Credentials? {
        .password(username: WebDAVIntegrationConfig.user, password: WebDAVIntegrationConfig.password)
    }
}

/// The certificate prompt, against a server whose certificate really is untrusted.
///
/// Caddy signs its own, so the system refuses it for the same reason it refuses a NAS or a Nextcloud in
/// a cupboard — which is the case this slice exists for.
@Suite(
    "WebDAV certificate trust",
    .enabled(if: WebDAVTLSConfig.isEnabled, "run via infra/integration/script.sh"),
    .serialized
)
struct WebDAVTrustIntegrationTests {

    private func makeHost() -> RemoteHost {
        RemoteHost(
            protocolIdentifier: .webdav,
            hostname: WebDAVIntegrationConfig.host ?? "localhost",
            port: WebDAVTLSConfig.port,
            username: WebDAVIntegrationConfig.user
        )
    }

    /// A store over a throwaway file, so a test never inherits or leaves trust behind.
    private func makeStore() -> (TrustedCertificateStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-trust-\(UUID().uuidString)/trusted.json")
        return (TrustedCertificateStore(fileURL: url), url)
    }

    private func makeSession(
        store: TrustedCertificateStore
    ) throws -> WebDAVSession {
        try #require(WebDAVSession(host: makeHost(), trustedCertificates: store))
    }

    // MARK: - Asking

    @Test("An untrusted certificate raises the question rather than failing")
    func asksAboutAnUntrustedCertificate() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let delegate = CountingTrustDelegate(answer: .acceptOnce)
        let session = try makeSession(store: store)
        try await session.connect(credentials: nil, delegate: delegate)

        #expect(await delegate.questionCount == 1)
        #expect(await session.isConnected, "accepting connects")
        await session.disconnect()
    }

    @Test("The question says what the certificate is and why it was refused")
    func challengeDescribesTheCertificate() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let delegate = CountingTrustDelegate(answer: .acceptOnce)
        let session = try makeSession(store: store)
        try await session.connect(credentials: nil, delegate: delegate)
        await session.disconnect()

        let challenge = try #require(await delegate.lastChallenge)
        #expect(challenge.hostname == "localhost")
        #expect(challenge.port == WebDAVTLSConfig.port)
        #expect(challenge.fingerprint.hasPrefix("SHA256:"))
        #expect(challenge.issuer.contains("Caddy"), "the issuer is named, not guessed")
        #expect(!challenge.problems.isEmpty, "“untrusted” alone tells the user nothing")
        #expect(challenge.trust == .unknown, "nothing on record yet")
    }

    @Test("The fingerprint is the one openssl computes")
    func fingerprintMatchesOpenSSL() async throws {
        // Checked against another tool rather than against our own arithmetic. A hash that is
        // self-consistently wrong is worse than none: it looks authoritative, and a user comparing it
        // against what their server reports would find a mismatch and assume the worst.
        let expected = try opensslFingerprint()

        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let delegate = CountingTrustDelegate(answer: .acceptOnce)
        let session = try makeSession(store: store)
        try await session.connect(credentials: nil, delegate: delegate)
        await session.disconnect()

        let ours = try #require(await delegate.lastChallenge?.fingerprint)
        #expect(ours == "SHA256:\(expected)")
    }

    @Test("Rejecting the certificate refuses the connection")
    func rejectingFailsTheConnection() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let delegate = CountingTrustDelegate(answer: .reject)
        let session = try makeSession(store: store)

        await #expect(throws: SessionError.self) {
            try await session.connect(credentials: nil, delegate: delegate)
        }
        #expect(await !session.isConnected)
    }

    // MARK: - Remembering

    @Test("Accepting and storing means the next connection does not ask")
    func acceptAndStoreIsRemembered() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = CountingTrustDelegate(answer: .acceptAndStore)
        let firstSession = try makeSession(store: store)
        try await firstSession.connect(credentials: nil, delegate: first)
        await firstSession.disconnect()
        #expect(await first.questionCount == 1)

        // A second session over the same store is what the next launch looks like.
        let second = CountingTrustDelegate(answer: .reject)
        let secondSession = try makeSession(store: store)
        try await secondSession.connect(credentials: nil, delegate: second)

        #expect(await second.questionCount == 0, "it was already answered, so nobody is asked again")
        #expect(await secondSession.isConnected)
        await secondSession.disconnect()
    }

    @Test("Accepting once lasts the connection and no longer")
    func acceptOnceLastsOneConnection() async throws {
        // The judgement call this slice makes: a download and an upload each build their own URLSession,
        // so "just this once" has to mean once per *connection* or a transfer would ask again and again.
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let delegate = CountingTrustDelegate(answer: .acceptOnce)
        let session = try makeSession(store: store)
        try await session.connect(credentials: nil, delegate: delegate)

        // Several more requests, each on the same session.
        _ = try await session.list(.root)
        _ = await session.exists(RemotePath("/nothing-here"))
        #expect(await delegate.questionCount == 1, "asked once, not once per request")

        // And nothing was written down, so a fresh connection asks again.
        #expect(await store.entries().isEmpty)
        await session.disconnect()

        let next = CountingTrustDelegate(answer: .acceptOnce)
        let nextSession = try makeSession(store: store)
        try await nextSession.connect(credentials: nil, delegate: next)
        #expect(await next.questionCount == 1, "“once” means once")
        await nextSession.disconnect()
    }

    @Test("A stored certificate that changes is reported as changed, not as unknown")
    func changedCertificateIsFlagged() async throws {
        // The serious case. A record that does not match means either a legitimate renewal or something
        // pretending to be the server, and the user cannot tell the difference without being told.
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.store(TrustedCertificate(
            hostname: "localhost", port: WebDAVTLSConfig.port,
            fingerprint: "SHA256:00:00:00", subject: "CN=localhost", issuer: "CN=someone else"
        ))

        let delegate = CountingTrustDelegate(answer: .reject)
        let session = try makeSession(store: store)
        _ = try? await session.connect(credentials: nil, delegate: delegate)

        let challenge = try #require(await delegate.lastChallenge)
        #expect(challenge.trust == .changed(previousFingerprint: "SHA256:00:00:00"),
                "and it carries what was stored, so both can be shown")
    }

    // MARK: - Helpers

    /// What `openssl` says the server's certificate fingerprint is.
    private func opensslFingerprint() throws -> String {
        let pipeline = Process()
        pipeline.executableURL = URL(fileURLWithPath: "/bin/sh")
        pipeline.arguments = [
            "-c",
            // `-servername` is not optional here: without SNI the server has no name to select a
            // certificate for, `s_client` produces nothing, and the second command reports a confusing
            // PEM error rather than saying the connection failed.
            "echo | openssl s_client -connect localhost:\(WebDAVTLSConfig.port) -servername localhost "
            + "2>/dev/null | openssl x509 -noout -fingerprint -sha256"
        ]

        let output = Pipe()
        pipeline.standardOutput = output
        try pipeline.run()
        pipeline.waitUntilExit()

        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let fingerprint = text
            .replacingOccurrences(of: "SHA256 Fingerprint=", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(!fingerprint.isEmpty, "openssl reported nothing; is the TLS container up?")
        return fingerprint
    }
}
