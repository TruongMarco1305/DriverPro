//
//  SSHAgentTests.swift
//  DPCredentialsTests
//

import DPTestSupport
import Foundation
import Testing
@testable import DPCredentials

/// The wire format, against bytes a real agent produced. See `SSHAgentFixtures` for how they were taken.
@Suite("ssh-agent wire format")
struct SSHAgentWireTests {

    // MARK: - Requests

    @Test("A request for identities is five bytes: a length, then the message number")
    func encodesRequestIdentities() {
        // The whole message, framed. Small enough to assert exactly, and worth doing so — an off-by-one
        // in the length prefix makes every reply look truncated.
        #expect(SSHAgentWire.requestIdentities() == Data([0x00, 0x00, 0x00, 0x01, 0x0b]))
    }

    @Test("A sign request carries the key blob, the payload, and the flags, each length-prefixed")
    func encodesSignRequest() throws {
        let blob = SSHAgentFixtures.keyBlob
        let payload = SSHAgentFixtures.signedPayload
        let message = SSHAgentWire.signRequest(keyBlob: blob, data: payload, flags: 0)

        var reader = ByteReader(message)
        #expect(reader.readUInt32() == UInt32(message.count - 4), "the frame length excludes itself")
        #expect(reader.readByte() == 13)
        #expect(reader.readSSHString() == blob, "the blob goes back exactly as the agent gave it")
        #expect(reader.readSSHString() == payload)
        #expect(reader.readUInt32() == 0)
        #expect(reader.remaining == 0, "nothing extra on the wire")
    }

    @Test("The RSA SHA-2 flags are the values OpenSSH defines")
    func rsaFlagValues() {
        // From PROTOCOL.agent. Getting these wrong produces a SHA-1 signature that a modern server
        // rejects, with nothing in the exchange to say why.
        #expect(SSHAgentWire.rsaSHA2_256 == 2)
        #expect(SSHAgentWire.rsaSHA2_512 == 4)
    }

    // MARK: - Identities

    @Test("A real agent's identity list parses, comment and algorithm included")
    func parsesCapturedIdentities() throws {
        let identities = try SSHAgentWire.identities(from: SSHAgentFixtures.identitiesAnswer)

        #expect(identities.count == 1)
        let identity = try #require(identities.first)
        #expect(identity.comment == SSHAgentFixtures.expectedComment)
        #expect(identity.algorithm == "ssh-ed25519")
        #expect(identity.keyBlob == SSHAgentFixtures.keyBlob,
                "the blob must match the key's own public key line, byte for byte")
    }

    @Test("The fingerprint of a key the agent reported matches ssh-keygen")
    func fingerprintAgreesWithOpenSSH() throws {
        // Ties the agent path to the host key path: both go through `HostKeyFingerprint`, and the value
        // here was taken from `ssh-keygen -lf` rather than from our own code.
        let identity = try #require(try SSHAgentWire.identities(
            from: SSHAgentFixtures.identitiesAnswer).first)
        #expect(identity.fingerprint == SSHAgentFixtures.expectedFingerprint)
    }

    @Test("A running agent holding nothing is an empty list, not an error")
    func parsesEmptyIdentityList() throws {
        #expect(try SSHAgentWire.identities(from: SSHAgentFixtures.emptyIdentitiesAnswer).isEmpty)
    }

    @Test("A truncated identity list is rejected rather than read past the end")
    func rejectsTruncatedIdentityList() {
        // The count says one key; the bytes for it are not there. This is the shape of every buffer
        // overread, and the reason each read returns an optional instead of trapping.
        let truncated = SSHAgentFixtures.identitiesAnswer.prefix(20)
        #expect(throws: CredentialError.self) {
            try SSHAgentWire.identities(from: Data(truncated))
        }
    }

    @Test("An implausible key count is refused before anything is allocated")
    func rejectsAbsurdKeyCount() {
        // A length field is data from outside the process even on a local socket. Without the cap this
        // would try to build a four-billion-element array.
        var payload = Data([0x0c])
        payload.appendUInt32(UInt32.max)
        #expect(throws: CredentialError.self) { try SSHAgentWire.identities(from: payload) }
    }

    // MARK: - Signatures

    @Test("A real agent's signature parses to the inner blob")
    func parsesCapturedSignature() throws {
        let signature = try SSHAgentWire.signature(from: SSHAgentFixtures.signResponse)

        // The blob is itself two SSH strings: the algorithm, then 64 bytes of Ed25519 signature. That
        // nesting is what the NIOSSH adapter unpicks, so it is asserted here rather than assumed.
        var reader = ByteReader(signature)
        #expect(reader.readSSHString().map { String(data: $0, encoding: .utf8) } == "ssh-ed25519")
        #expect(reader.readSSHString()?.count == 64)
        #expect(reader.remaining == 0)
    }

    @Test("An explicit refusal says the agent refused, not that the bytes were bad")
    func reportsFailureAsRefusal() throws {
        // A locked agent, or a key removed since the list was fetched. Ordinary, and worth its own
        // message: "the agent refused" sends the user to `ssh-add`, a parse error sends them nowhere.
        // `#expect(throws:)` hands back the error it caught, so the message can be inspected too.
        let error = #expect(throws: CredentialError.self) {
            try SSHAgentWire.signature(from: SSHAgentFixtures.failure)
        }

        guard case .agent(let reason) = try #require(error) else {
            Issue.record("expected an agent error, got \(error)")
            return
        }
        #expect(reason.contains("refused"))
    }

    @Test("An unexpected message number is reported with the number")
    func reportsUnexpectedMessage() {
        #expect(throws: CredentialError.self) {
            try SSHAgentWire.identities(from: Data([0x63]))
        }
    }

    @Test("An empty reply is an error rather than an empty result")
    func rejectsEmptyReply() {
        #expect(throws: CredentialError.self) { try SSHAgentWire.identities(from: Data()) }
    }
}

// MARK: - Client

/// The client, over a scripted transport — no socket, no agent.
@Suite("SSHAgentClient")
struct SSHAgentClientTests {

    @Test("Listing identities sends a request for identities and returns what came back")
    func listsIdentities() throws {
        let transport = StubAgentTransport(replies: [SSHAgentFixtures.identitiesAnswer])
        let identities = try SSHAgentClient(transport: transport).identities()

        #expect(identities.count == 1)
        #expect(transport.requests == [SSHAgentWire.requestIdentities()])
    }

    @Test("Signing sends the blob the agent reported, unaltered")
    func signsWithTheReportedBlob() throws {
        // The agent matches a key by these exact bytes. Re-encoding the blob — even into something
        // equivalent — risks producing something it will not recognise, and the failure looks like a
        // rejected login rather than a client bug.
        let transport = StubAgentTransport(replies: [SSHAgentFixtures.signResponse])
        let identity = SSHAgentIdentity(keyBlob: SSHAgentFixtures.keyBlob, comment: "k")

        _ = try SSHAgentClient(transport: transport).signature(
            for: SSHAgentFixtures.signedPayload, using: identity)

        var reader = ByteReader(try #require(transport.requests.first))
        _ = reader.readUInt32()
        #expect(reader.readByte() == 13)
        #expect(reader.readSSHString() == SSHAgentFixtures.keyBlob)
    }

    @Test("A transport failure reaches the caller rather than being turned into an empty list")
    func transportFailurePropagates() {
        let transport = StubAgentTransport(failure: CredentialError.agent(reason: "no socket"))
        #expect(throws: CredentialError.self) { try SSHAgentClient(transport: transport).identities() }
    }

    @Test("No SSH_AUTH_SOCK in the environment means no client, not a broken one")
    func noAgentMeansNoClient() {
        // The connection sheet asks this to decide whether to offer the option at all, so "there is no
        // agent" has to be an ordinary answer rather than an error to handle.
        #expect(SSHAgentClient(environment: [:]) == nil)
        #expect(SSHAgentClient(environment: ["SSH_AUTH_SOCK": ""]) == nil)
        #expect(SSHAgentClient(environment: ["SSH_AUTH_SOCK": "/tmp/whatever"]) != nil)
    }
}

// MARK: - The socket

/// The Unix socket transport, against a fake agent on a real socket.
///
/// Everything above uses `StubAgentTransport`, which means none of it touches `sockaddr_un`, the timeouts,
/// or the short-read loop — the three things most likely to be wrong. This suite exists for those.
@Suite("UnixSocketAgentTransport", .serialized)
struct UnixSocketAgentTransportTests {

    @Test("A round trip over a real socket returns the agent's reply")
    func exchangesOverASocket() throws {
        let agent = try FakeSSHAgent(behaviour: .replies([SSHAgentFixtures.identitiesAnswer]))
        defer { agent.stop() }

        let client = SSHAgentClient(transport: UnixSocketAgentTransport(socketPath: agent.socketPath))
        #expect(try client.identities().count == 1)
        #expect(agent.requestsServed == 1)
    }

    @Test("Each exchange opens its own connection")
    func oneConnectionPerExchange() throws {
        // No pooled descriptor means no shared mutable state and no lock. `ssh` reconnects per operation
        // too, and agents are built for it.
        let agent = try FakeSSHAgent(behaviour: .replies([
            SSHAgentFixtures.identitiesAnswer, SSHAgentFixtures.signResponse
        ]))
        defer { agent.stop() }

        let client = SSHAgentClient(transport: UnixSocketAgentTransport(socketPath: agent.socketPath))
        let identity = try #require(try client.identities().first)
        _ = try client.signature(for: SSHAgentFixtures.signedPayload, using: identity)

        #expect(agent.requestsServed == 2)
    }

    @Test("An agent that never answers trips the receive timeout")
    func silentAgentTimesOut() throws {
        // The reason the timeout exists: this call blocks a NIOSSH event loop thread. Without a ceiling,
        // a wedged agent would hang the connection for as long as the process lives.
        let agent = try FakeSSHAgent(behaviour: .silence)
        defer { agent.stop() }

        let transport = UnixSocketAgentTransport(socketPath: agent.socketPath, timeout: 0.2)
        let started = Date()
        #expect(throws: CredentialError.self) { try transport.exchange(SSHAgentWire.requestIdentities()) }
        #expect(Date().timeIntervalSince(started) < 3, "it should have given up after ~0.2s")
    }

    @Test("An agent that hangs up mid-message is reported, not read as an empty reply")
    func earlyCloseIsAnError() throws {
        let agent = try FakeSSHAgent(behaviour: .hangUp)
        defer { agent.stop() }

        let transport = UnixSocketAgentTransport(socketPath: agent.socketPath)
        #expect(throws: CredentialError.self) { try transport.exchange(SSHAgentWire.requestIdentities()) }
    }

    @Test("A socket that is not there is reported clearly")
    func missingSocketIsReported() {
        let transport = UnixSocketAgentTransport(
            socketPath: (NSTemporaryDirectory() as NSString).appendingPathComponent("dp-absent.sock"))
        #expect(throws: CredentialError.self) { try transport.exchange(SSHAgentWire.requestIdentities()) }
    }

    @Test("Something that is not a socket is refused before connecting")
    func nonSocketIsRefused() throws {
        // `SSH_AUTH_SOCK` is an environment variable, so it can point anywhere. Checking the file type
        // and owner is what stops a planted path being asked to sign.
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-not-a-socket-\(UUID().uuidString)")
        try Data("plain file".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let transport = UnixSocketAgentTransport(socketPath: file.path)
        #expect(throws: CredentialError.self) { try transport.exchange(SSHAgentWire.requestIdentities()) }
    }

    @Test("A socket path too long for sockaddr_un is refused rather than silently truncated")
    func overlongPathIsRefused() {
        // 104 bytes on Darwin, and a longer path is truncated without complaint — which surfaces as
        // "no such file" for a socket that is plainly there. Worth failing loudly instead.
        let long = "/tmp/" + String(repeating: "a", count: 200) + ".sock"
        let transport = UnixSocketAgentTransport(socketPath: long)
        #expect(throws: CredentialError.self) { try transport.exchange(SSHAgentWire.requestIdentities()) }
    }
}
