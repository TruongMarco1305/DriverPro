//
//  AgentKeyBlobTests.swift
//  DPProtocolSFTPTests
//

import Crypto
import DPCore
import DPCredentials
import DPTestSupport
import Foundation
import NIOCore
import Testing
@preconcurrency import NIOSSH
@testable import DPProtocolSFTP

/// What an agent-backed key puts on the wire.
///
/// This suite exists for one failure mode. NIOSSH writes a custom key's algorithm name itself and then
/// calls `write(to:)` for the body, so a `write(to:)` that helpfully includes the name again produces a
/// blob with two names in it. A server rejects that as an authentication failure and says nothing about
/// why — so without a byte-level assertion here, the bug would surface only as "the key does not work",
/// against a real server, with nothing to point at.
@Suite("Agent key blobs")
struct AgentKeyBlobTests {

    // MARK: - Building fixtures

    /// An SSH string: a 4-byte big-endian length, then the bytes.
    private func sshString(_ bytes: Data) -> Data {
        var out = Data()
        let count = UInt32(bytes.count)
        out.append(contentsOf: [
            UInt8(truncatingIfNeeded: count >> 24), UInt8(truncatingIfNeeded: count >> 16),
            UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count),
        ])
        out.append(bytes)
        return out
    }

    private func sshString(_ text: String) -> Data { sshString(Data(text.utf8)) }

    /// A real Ed25519 key, and the OpenSSH public key blob an agent would report for it.
    private func makeKey() -> (private: Curve25519.Signing.PrivateKey, blob: Data) {
        let key = Curve25519.Signing.PrivateKey()
        let blob = sshString("ssh-ed25519") + sshString(key.publicKey.rawRepresentation)
        return (key, blob)
    }

    /// The bytes NIOSSH writes for a public key, using its own public `write(to:)`.
    private func serialised(_ key: NIOSSHPublicKey) -> Data {
        var buffer = ByteBufferAllocator().buffer(capacity: 128)
        key.write(to: &buffer)
        return Data(buffer.readableBytesView)
    }

    // MARK: - The public key

    @Test("An agent-backed key writes exactly the blob the agent reported")
    func writesTheAgentsBlobVerbatim() throws {
        // The cleanest statement of the invariant. The agent hands over `string(algorithm) || body`;
        // NIOSSH writes `string(prefix)` and then our `write(to:)`. So if the prefix and the body are
        // right, the result is the agent's own bytes back again — and if `write(to:)` re-emitted the
        // algorithm name, this would be longer than the original.
        let (_, blob) = makeKey()
        let identity = SSHAgentIdentity(keyBlob: blob, comment: "work laptop")
        let client = SSHAgentClient(transport: StubAgentTransport(replies: []))

        let key = try #require(AgentSignedKey<Ed25519Agent>(client: client, identity: identity))
        #expect(serialised(NIOSSHPrivateKey(custom: key).publicKey) == blob)
    }

    @Test("An agent-backed key serialises identically to the same key parsed natively")
    func matchesTheNativeKeyByteForByte() throws {
        // The other direction of the same guarantee, and the stronger one: NIOSSH's own Ed25519 path is
        // known to interoperate, so producing the same bytes is proof rather than self-agreement.
        let (privateKey, blob) = makeKey()
        let native = NIOSSHPrivateKey(ed25519Key: privateKey).publicKey

        let identity = SSHAgentIdentity(keyBlob: blob, comment: "")
        let client = SSHAgentClient(transport: StubAgentTransport(replies: []))
        let agentKey = try #require(AgentSignedKey<Ed25519Agent>(client: client, identity: identity))

        #expect(serialised(NIOSSHPrivateKey(custom: agentKey).publicKey) == serialised(native))
    }

    @Test("A key whose blob names a different algorithm is refused at construction")
    func refusesAMismatchedAlgorithm() {
        // `AgentSignedKey<Ed25519Agent>` claims `ssh-ed25519` in its statics. Building one around an
        // ECDSA blob would advertise one algorithm and send another's bytes.
        let blob = sshString("ecdsa-sha2-nistp256") + sshString(Data(repeating: 7, count: 32))
        let identity = SSHAgentIdentity(keyBlob: blob, comment: "")
        let client = SSHAgentClient(transport: StubAgentTransport(replies: []))

        #expect(AgentSignedKey<Ed25519Agent>(client: client, identity: identity) == nil)
    }

    @Test("A malformed blob is refused rather than producing a key that cannot work")
    func refusesAMalformedBlob() {
        let identity = SSHAgentIdentity(keyBlob: Data([0x00, 0x00]), comment: "")
        let client = SSHAgentClient(transport: StubAgentTransport(replies: []))
        #expect(AgentSignedKey<Ed25519Agent>(client: client, identity: identity) == nil)
    }

    // MARK: - The signature

    @Test("A signature writes the body only, because NIOSSH writes the prefix")
    func signatureWritesTheBodyOnly() throws {
        // NIOSSH's `writeSSHSignature` does `writeSSHString(sig.signaturePrefix)` and then `sig.write(to:)`
        // (NIOSSHSignature.swift, the `.custom` case). So `write(to:)` must emit everything after the
        // algorithm name in the agent's reply, and nothing more.
        let (_, blob) = makeKey()
        let signatureBytes = Data(repeating: 0xAB, count: 64)
        let signatureBlob = sshString("ssh-ed25519") + sshString(signatureBytes)
        let response = Data([0x0e]) + sshString(signatureBlob)

        let identity = SSHAgentIdentity(keyBlob: blob, comment: "")
        let client = SSHAgentClient(transport: StubAgentTransport(replies: [response]))
        let key = try #require(AgentSignedKey<Ed25519Agent>(client: client, identity: identity))

        let signature = try key.signature(for: Data("anything".utf8))
        var buffer = ByteBufferAllocator().buffer(capacity: 128)
        signature.write(to: &buffer)

        #expect(Data(buffer.readableBytesView) == sshString(signatureBytes))
        #expect(type(of: signature).signaturePrefix == "ssh-ed25519")
    }

    @Test("A signature the agent made with a different algorithm is refused, not sent")
    func refusesAnUnexpectedSignatureAlgorithm() throws {
        // An agent asked for `ssh-rsa` may answer `rsa-sha2-512`. That is a better signature, and this
        // transport cannot carry it — the algorithm name and the key blob's own name would disagree. Saying
        // so is better than sending a blob the server will reject without explanation.
        let (_, blob) = makeKey()
        let signatureBlob = sshString("rsa-sha2-512") + sshString(Data(repeating: 1, count: 64))
        let response = Data([0x0e]) + sshString(signatureBlob)

        let identity = SSHAgentIdentity(keyBlob: blob, comment: "")
        let client = SSHAgentClient(transport: StubAgentTransport(replies: [response]))
        let key = try #require(AgentSignedKey<Ed25519Agent>(client: client, identity: identity))

        #expect(throws: SessionError.self) { _ = try key.signature(for: Data("anything".utf8)) }
    }

    @Test("A refusal from the agent reaches the caller as an error, not an empty signature")
    func agentRefusalPropagates() throws {
        let (_, blob) = makeKey()
        let identity = SSHAgentIdentity(keyBlob: blob, comment: "")
        // Message 5 is SSH_AGENT_FAILURE — a locked agent, or a key it no longer holds.
        let client = SSHAgentClient(transport: StubAgentTransport(replies: [Data([0x05])]))
        let key = try #require(AgentSignedKey<Ed25519Agent>(client: client, identity: identity))

        #expect(throws: (any Error).self) { _ = try key.signature(for: Data("anything".utf8)) }
    }

    // MARK: - Building the offer chain

    @Test("Every algorithm the adapter claims to support produces an offer")
    func supportedAlgorithmsBecomeOffers() {
        let client = SSHAgentClient(transport: StubAgentTransport(replies: []))
        let bodies: [(String, Int)] = [
            ("ssh-ed25519", 32), ("ecdsa-sha2-nistp256", 65),
            ("ecdsa-sha2-nistp384", 97), ("ecdsa-sha2-nistp521", 133), ("ssh-rsa", 140),
        ]

        for (algorithm, size) in bodies {
            let identity = SSHAgentIdentity(
                keyBlob: sshString(algorithm) + sshString(Data(repeating: 3, count: size)),
                comment: "k")
            #expect(client.offers(from: [identity]).count == 1, "\(algorithm) produced no offer")
        }
    }

    @Test("An algorithm the transport cannot carry is skipped, and the rest still offered")
    func unsupportedAlgorithmsAreSkipped() {
        // FIDO keys, certificates and DSA cannot be expressed as a NIOSSH custom key. One unusable key in
        // an agent must not stop the usable ones from being tried.
        let client = SSHAgentClient(transport: StubAgentTransport(replies: []))
        let unusable = ["sk-ssh-ed25519@openssh.com", "ssh-ed25519-cert-v01@openssh.com", "ssh-dss"]
            .map { SSHAgentIdentity(keyBlob: sshString($0) + sshString(Data(repeating: 4, count: 32)),
                                    comment: "exotic") }
        let usable = SSHAgentIdentity(
            keyBlob: sshString("ssh-ed25519") + sshString(Data(repeating: 5, count: 32)), comment: "good")

        var skipped: [String] = []
        let offers = client.offers(from: unusable + [usable], log: { skipped.append($0) })

        #expect(offers.count == 1)
        #expect(skipped.count == 3, "each skipped key should say so in the transcript")
    }

    @Test("Offers are capped, so the server's attempt budget is not exhausted mid-chain")
    func offersAreCapped() {
        // sshd's MaxAuthTries defaults to 6 and every public key offer spends one. Running out looks like
        // a dropped connection rather than a refusal, so the cap is a correctness matter, not tidiness.
        let client = SSHAgentClient(transport: StubAgentTransport(replies: []))
        let identities = (0..<9).map { index in
            SSHAgentIdentity(
                keyBlob: sshString("ssh-ed25519") + sshString(Data(repeating: UInt8(index), count: 32)),
                comment: "key \(index)")
        }

        var notices: [String] = []
        let offers = client.offers(from: identities, limit: 4, log: { notices.append($0) })

        #expect(offers.count == 4)
        #expect(notices.contains { $0.contains("5") }, "the user should be told how many were left out")
    }

    // MARK: - What a failing agent tells the user

    /// A session pointed at an agent of our choosing, and at a server that does not exist.
    ///
    /// Nothing here reaches the network: every case below fails while *preparing* the offer, which is the
    /// whole point — these are the messages a user sees when their agent is not set up, and they should not
    /// need a server to be tested.
    private func session(agent: @escaping @Sendable () -> SSHAgentClient?) -> SFTPSession {
        SFTPSession(
            host: RemoteHost(protocolIdentifier: .sftp, hostname: "127.0.0.1", port: 1, username: "duck"),
            knownHosts: KnownHostsStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "dp-known_hosts-\(UUID().uuidString)")),
            makeAgent: agent
        )
    }

    /// Connects and returns the reason it failed.
    private func failureReason(agent: @escaping @Sendable () -> SSHAgentClient?) async throws -> String {
        let error = await #expect(throws: SessionError.self) {
            try await session(agent: agent).connect(
                credentials: .sshAgent(username: "duck"),
                delegate: ScriptedDelegate(hostKeyDecision: .acceptOnce, credentials: nil)
            )
        }
        guard case .authenticationFailed(let reason) = try #require(error) else {
            throw SessionError.protocolViolation("expected an authentication failure, got \(error as Any)")
        }
        return reason
    }

    @Test("With no agent running, the message says so and suggests ssh-add")
    func noAgentExplainsItself() async throws {
        let reason = try await failureReason(agent: { nil })
        #expect(reason.contains("ssh-add"), "the actionable part: \(reason)")
    }

    @Test("An agent holding no keys says that, which is a different problem from having no agent")
    func emptyAgentExplainsItself() async throws {
        // The same shape as a real agent after `ssh-add -D`. Only this one is fixed by adding a key, so the
        // two must not share a message.
        let reason = try await failureReason(agent: {
            SSHAgentClient(transport: StubAgentTransport(replies: [Data([0x0c, 0x00, 0x00, 0x00, 0x00])]))
        })
        #expect(reason.contains("no keys"))
        #expect(reason.contains("ssh-add"))
    }

    @Test("An agent holding only keys we cannot offer says that, and recommends Ed25519")
    func unusableAgentKeysExplainThemselves() async throws {
        // A FIDO key. The agent is running and loaded, and still nothing can be offered — the least
        // guessable of the three failures, so the message has to be specific.
        let blob = sshString("sk-ssh-ed25519@openssh.com") + sshString(Data(repeating: 9, count: 32))
        // `let`, because the closure below is `@Sendable` and cannot capture a `var`.
        let answer = Data([0x0c, 0x00, 0x00, 0x00, 0x01]) + sshString(blob) + sshString("hardware key")

        let reason = try await failureReason(agent: {
            SSHAgentClient(transport: StubAgentTransport(replies: [answer]))
        })
        #expect(reason.contains("Ed25519"))
    }

    @Test("An agent that cannot be reached reports that, rather than reporting a refusal")
    func unreachableAgentExplainsItself() async throws {
        let reason = try await failureReason(agent: {
            SSHAgentClient(transport: StubAgentTransport(failure: CredentialError.agent(reason: "no socket")))
        })
        #expect(reason.lowercased().contains("agent"))
    }

    @Test("An offer's label names the key without revealing anything secret")
    func offerLabelsAreSafeToShow() throws {
        let client = SSHAgentClient(transport: StubAgentTransport(replies: []))
        let identity = SSHAgentIdentity(
            keyBlob: sshString("ssh-ed25519") + sshString(Data(repeating: 6, count: 32)),
            comment: "work laptop")

        let offer = try #require(client.offers(from: [identity]).first)
        #expect(offer.label.contains("work laptop"))
        #expect(offer.label.contains("ssh-ed25519"))
    }
}
