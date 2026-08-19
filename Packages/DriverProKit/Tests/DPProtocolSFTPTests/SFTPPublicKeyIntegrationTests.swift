//
//  SFTPPublicKeyIntegrationTests.swift
//  DPProtocolSFTPTests
//

import DPCore
import DPCredentials
import DPTestSupport
import Foundation
import Testing
@testable import DPProtocolSFTP

/// Key authentication against a real SSH server.
///
/// The hermetic suites prove the bytes are right. This one proves a server accepts them — which is a
/// different claim, and the only one that matters. `infra/integration/script.sh` generates the keys and
/// installs the public halves in the container.
///
/// **These tests never touch `~/.ssh/known_hosts`** — each gets a throwaway file.
@Suite(
    "SFTP public key integration",
    .enabled(if: IntegrationConfig.hasKeys, "run via infra/integration/script.sh"),
    .serialized
)
struct SFTPPublicKeyIntegrationTests {

    // MARK: - Fixtures

    private func makeHost() -> RemoteHost {
        RemoteHost(
            protocolIdentifier: .sftp,
            hostname: IntegrationConfig.host ?? "localhost",
            port: IntegrationConfig.port,
            username: IntegrationConfig.user
        )
    }

    private func makeThrowawayKnownHosts() -> KnownHostsStore {
        KnownHostsStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("dp-known_hosts-\(UUID().uuidString)")
        )
    }

    /// A session pointed at the container, trusting whatever host key it presents.
    private func makeSession() -> SFTPSession {
        SFTPSession(host: makeHost(), knownHosts: makeThrowawayKnownHosts())
    }

    /// Credentials built from a key file on disk, the way `CredentialCoordinator` would build them.
    private func keyCredentials(at path: String, passphrase: String? = nil) throws -> Credentials {
        Credentials.privateKey(
            username: IntegrationConfig.user,
            data: try Data(contentsOf: URL(fileURLWithPath: path)),
            passphrase: passphrase,
            path: path
        )
    }

    // MARK: - The happy paths

    @Test("An unencrypted Ed25519 key logs in and lists a directory")
    func connectsWithAnUnencryptedKey() async throws {
        let path = try #require(IntegrationConfig.keyPath)
        let session = makeSession()
        defer { Task { await session.disconnect() } }

        try await session.connect(
            credentials: try keyCredentials(at: path),
            delegate: ScriptedDelegate(hostKeyDecision: .acceptOnce)
        )

        // Listing, not just connecting: authentication succeeding but the SFTP subsystem failing to open
        // would otherwise look like a pass.
        _ = try await session.list(RemotePath(IntegrationConfig.basePath))
    }

    @Test("An encrypted Ed25519 key logs in when given the right passphrase")
    func connectsWithAnEncryptedKey() async throws {
        let path = try #require(IntegrationConfig.encryptedKeyPath)
        let session = makeSession()
        defer { Task { await session.disconnect() } }

        try await session.connect(
            credentials: try keyCredentials(at: path, passphrase: IntegrationConfig.keyPassphrase),
            delegate: ScriptedDelegate(hostKeyDecision: .acceptOnce)
        )
        _ = try await session.list(RemotePath(IntegrationConfig.basePath))
    }

    // MARK: - The failures, and what they say

    @Test("The wrong passphrase says so, and does not become a story about the server")
    func wrongPassphraseExplainsItself() async throws {
        // This one never reaches the server: the key cannot be decrypted locally. So it must *not* be
        // retried — a retry would replace this message with the next attempt's "the server rejected the
        // credentials" and send the user to look at the server instead of at what they typed. The delegate
        // here would happily supply a password if asked, which is exactly the trap.
        let path = try #require(IntegrationConfig.encryptedKeyPath)
        let session = makeSession()
        let delegate = RecordingDelegate(credentials: nil)

        let error = await #expect(throws: SessionError.self) {
            try await session.connect(
                credentials: try keyCredentials(at: path, passphrase: "not the passphrase"),
                delegate: delegate
            )
        }

        guard case .authenticationFailed(let reason) = try #require(error) else {
            Issue.record("expected an authentication failure, got \(String(describing: error))")
            return
        }
        #expect(reason.lowercased().contains("passphrase"))
        #expect(await delegate.requests.isEmpty, "nothing reached the server, so nothing was worth asking")
    }

    @Test("An RSA key the server authorises is still refused, and the retry prompt says why")
    func rsaIsRefusedWithAnExplanation() async throws {
        // ADR 014. The public half *is* installed on the server, so this refusal is entirely our
        // transport's SHA-1-only signing. If this test ever starts passing, the transport was replaced and
        // ADR 014 should be superseded.
        //
        // The advice reaches the user through the *retry prompt* — the sheet that says "the server rejected
        // the previous attempt: …" — which is where somebody whose RSA key just failed is actually looking.
        let path = try #require(IntegrationConfig.rsaKeyPath)
        let session = makeSession()
        let delegate = RecordingDelegate(credentials: nil)   // declines the fallback

        let error = await #expect(throws: SessionError.self) {
            try await session.connect(credentials: try keyCredentials(at: path), delegate: delegate)
        }

        let asked = try #require(await delegate.requests.first)
        guard case .retry(let afterFailure) = asked.reason else {
            Issue.record("expected a retry request, got \(asked.reason)")
            return
        }
        #expect(afterFailure.contains("RSA"), "a bare failure would send the user hunting: \(afterFailure)")
        #expect(afterFailure.contains("Ed25519"), "and it should say what to do instead")

        // Declining the fallback leaves the informative error as the one that surfaces.
        guard case .authenticationFailed(let reason) = try #require(error) else {
            Issue.record("expected an authentication failure")
            return
        }
        #expect(reason.contains("RSA"))
    }

    @Test("A key the server does not know falls back to a password, in one retry")
    func unknownKeyFallsBackToAPassword() async throws {
        // The fallback chain end to end, and the reason `connect` retries at all. The delegate answers the
        // first request with a key the server has never seen, and the retry with the right password.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-unknown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A syntactically valid Ed25519 key that the server has never heard of. Generated here rather than
        // committed, and thrown away with the directory.
        let strangerPath = directory.appending(path: "stranger").path
        let generate = Process()
        generate.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        generate.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "stranger", "-f", strangerPath]
        try generate.run()
        generate.waitUntilExit()
        try #require(generate.terminationStatus == 0, "ssh-keygen should have produced a key")

        let session = makeSession()
        defer { Task { await session.disconnect() } }

        let delegate = FallbackDelegate(
            first: try keyCredentials(at: strangerPath),
            second: .password(username: IntegrationConfig.user, password: IntegrationConfig.password)
        )
        try await session.connect(credentials: nil, delegate: delegate)

        _ = try await session.list(RemotePath(IntegrationConfig.basePath))
        #expect(await delegate.requestCount == 2, "exactly one retry, no more")
        #expect(await delegate.sawRetryReason, "the second question should say the first was refused")
    }
}

// MARK: - Delegates

/// Records every credential request and answers each one the same way.
///
/// The recording is the point: "was the user asked at all, and what were they told?" is what several of
/// these tests are actually about.
private actor RecordingDelegate: SessionDelegate {

    private let credentials: Credentials?
    private(set) var requests: [CredentialRequest] = []

    init(credentials: Credentials?) {
        self.credentials = credentials
    }

    func session(_ host: RemoteHost, needsHostKeyVerification challenge: HostKeyChallenge) async -> HostKeyDecision {
        .acceptOnce
    }

    func session(_ host: RemoteHost, needsCredentials request: CredentialRequest) async -> Credentials? {
        requests.append(request)
        return credentials
    }
}

/// Answers the first credential request with one thing and the second with another.
///
/// Exists to exercise the single retry in `SFTPSession.connect`: a refused key, then a password. Counting
/// the questions is how "exactly one retry" becomes assertable rather than assumed.
private actor FallbackDelegate: SessionDelegate {

    private let first: Credentials
    private let second: Credentials
    private(set) var requestCount = 0
    private(set) var sawRetryReason = false

    init(first: Credentials, second: Credentials) {
        self.first = first
        self.second = second
    }

    func session(_ host: RemoteHost, needsHostKeyVerification challenge: HostKeyChallenge) async -> HostKeyDecision {
        .acceptOnce
    }

    func session(_ host: RemoteHost, needsCredentials request: CredentialRequest) async -> Credentials? {
        requestCount += 1
        if case .retry = request.reason { sawRetryReason = true }
        return requestCount == 1 ? first : second
    }
}
