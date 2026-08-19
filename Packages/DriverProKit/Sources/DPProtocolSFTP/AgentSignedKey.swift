//
//  AgentSignedKey.swift
//  DPProtocolSFTP
//

import DPCore
import DPCredentials
import Foundation
import NIOCore

// See SFTPAuthenticationDelegate.swift for why this import carries `@preconcurrency`.
@preconcurrency import NIOSSH

// MARK: - Algorithms

/// One SSH public key algorithm, as a type.
///
/// ## Swift note — a phantom type parameter, and why it is forced here
///
/// `NIOSSHPrivateKeyProtocol` requires `static var keyPrefix: String`. **Static**, so the algorithm name
/// belongs to the *type* and not to the value — which means one type cannot serve two algorithms, however
/// convenient that would be. An agent may hold an Ed25519 key and an ECDSA key at once, so a single
/// `AgentSignedKey` struct with an `algorithm` property is not expressible.
///
/// The alternative to four near-identical copy-pasted structs is to make the algorithm a *type parameter*:
/// `AgentSignedKey<Ed25519Agent>` and `AgentSignedKey<P256Agent>` are genuinely different types, so they
/// can genuinely have different statics, while sharing one implementation. The parameter is called a
/// *phantom* type because no stored property ever has type `A` — it exists only to carry a fact to the
/// compiler. `enum` rather than `struct` for the markers, so nobody can accidentally make an instance of
/// something that is not meant to have instances.
protocol AgentAlgorithm {
    /// The algorithm's name on the wire, such as `"ssh-ed25519"`.
    ///
    /// This one string is used in three places, and they must agree: the algorithm field of the
    /// authentication request, the type string inside the public key blob, and the type string inside the
    /// signature. NIOSSH derives all three from the statics, which is exactly why RSA's modern
    /// `rsa-sha2-*` signatures cannot be expressed here — they need the first to differ from the second.
    /// See `docs/decisions/014-rsa-public-key-authentication-is-unavailable.md`.
    static var sshName: String { get }
}

/// Ed25519 — the algorithm that works everywhere and the one to recommend.
enum Ed25519Agent: AgentAlgorithm { static let sshName = "ssh-ed25519" }
/// ECDSA over NIST P-256. Reachable through an agent, but not from a key file — Citadel cannot parse one.
enum P256Agent: AgentAlgorithm { static let sshName = "ecdsa-sha2-nistp256" }
/// ECDSA over NIST P-384.
enum P384Agent: AgentAlgorithm { static let sshName = "ecdsa-sha2-nistp384" }
/// ECDSA over NIST P-521.
enum P521Agent: AgentAlgorithm { static let sshName = "ecdsa-sha2-nistp521" }
/// RSA, signed with SHA-1. Offered because it may work against an older server; see ADR 014.
enum RSAAgent: AgentAlgorithm { static let sshName = "ssh-rsa" }

// MARK: - Blob helpers

/// Splitting an SSH blob into its algorithm name and everything after it.
///
/// Both the public key and the signature arrive from the agent as `string(algorithm) || body`, and NIOSSH
/// writes the algorithm string itself before calling `write(to:)`. So in both cases what we must hand back
/// is *the body alone* — writing the algorithm again would produce a blob with two names in it, which the
/// server rejects for reasons it does not explain. Confirmed against bytes captured from a real agent; see
/// `SSHAgentFixtures`.
enum SSHBlob {

    /// Splits a blob into its leading algorithm name and the remaining bytes.
    ///
    /// - Parameter blob: `string(algorithm)` followed by algorithm-specific bytes.
    /// - Returns: The name and the body, or `nil` if the blob is malformed.
    static func split(_ blob: Data) -> (algorithm: String, body: Data)? {
        guard let algorithm = HostKeyFingerprint.algorithmName(ofKeyBlob: blob) else { return nil }
        return (algorithm, blob.dropFirst(4 + algorithm.utf8.count))
    }
}

// MARK: - Signature

/// A signature an ssh-agent produced.
struct AgentSignature<A: AgentAlgorithm>: NIOSSHSignatureProtocol {

    static var signaturePrefix: String { A.sshName }

    /// The signature body — everything after the algorithm name in the agent's reply.
    let rawRepresentation: Data

    @discardableResult
    func write(to buffer: inout ByteBuffer) -> Int {
        // The body only. NIOSSH has already written the prefix.
        buffer.writeData(rawRepresentation)
    }

    /// Never called on this side of the conversation.
    ///
    /// `read(from:)` exists so a *server* can parse a signature of this type. DriverPro is only ever the
    /// client: it produces these and never receives one. Throwing is more honest than inventing a value
    /// that would be silently wrong if the assumption ever changed.
    static func read(from buffer: inout ByteBuffer) throws -> Self {
        throw SessionError.protocolViolation("an agent signature cannot be read back from the wire")
    }
}

// MARK: - Public key

/// The public half of a key an ssh-agent holds.
struct AgentPublicKey<A: AgentAlgorithm>: NIOSSHPublicKeyProtocol {

    static var publicKeyPrefix: String { A.sshName }

    /// The key body — everything after the algorithm name in the blob the agent reported.
    let rawRepresentation: Data

    @discardableResult
    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeData(rawRepresentation)
    }

    /// Always `false`, because this key cannot verify anything.
    ///
    /// Verification is a server's job, and DriverPro never performs it with one of these: server host keys
    /// arrive as NIOSSH's own key types and go through `HostKeyVerifier`. Returning `false` is the safe
    /// direction — a wrong `true` would be a security bug, a wrong `false` cannot authorise anything.
    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        false
    }

    /// Never called. See ``AgentSignature/read(from:)``.
    static func read(from buffer: inout ByteBuffer) throws -> Self {
        throw SessionError.protocolViolation("an agent public key cannot be read back from the wire")
    }
}

// MARK: - Private key

/// A key whose private half lives inside an ssh-agent, which signs on our behalf.
///
/// The point of an agent is that the private key never leaves it — not even to us. So this type holds no
/// key material at all: it holds the *public* blob, which identifies which key to use, and a client to ask.
///
/// ## The blocking call, and why it is unavoidable
///
/// ``signature(for:)`` is synchronous because `NIOSSHPrivateKeyProtocol` says it is, and NIOSSH calls it on
/// the channel's event loop while building the authentication request. There is no `await` to be had inside
/// it, and the payload cannot be signed in advance because it includes the session identifier from a
/// handshake that has not finished. So a local socket round trip happens on an event loop thread.
///
/// Three things keep that from mattering: the transport's send/receive timeout bounds it, it happens once
/// per authentication attempt rather than per operation, and `SFTPSession` gives an agent-authenticated
/// connection its own single-threaded event loop group so a Touch ID prompt on a hardware key cannot stall
/// an unrelated transfer. `docs/swift-notes.md` §32 has the longer version.
struct AgentSignedKey<A: AgentAlgorithm>: NIOSSHPrivateKeyProtocol {

    static var keyPrefix: String { A.sshName }

    private let client: SSHAgentClient
    private let identity: SSHAgentIdentity
    private let body: Data

    /// Creates a key backed by an agent identity.
    ///
    /// - Parameters:
    ///   - client: How to reach the agent.
    ///   - identity: Which key the agent should use.
    /// - Returns: `nil` if the identity's blob is malformed or names a different algorithm than `A`.
    init?(client: SSHAgentClient, identity: SSHAgentIdentity) {
        guard let split = SSHBlob.split(identity.keyBlob), split.algorithm == A.sshName else {
            return nil
        }
        self.client = client
        self.identity = identity
        self.body = split.body
    }

    var publicKey: NIOSSHPublicKeyProtocol {
        AgentPublicKey<A>(rawRepresentation: body)
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let blob = try client.signature(for: Data(data), using: identity)

        guard let split = SSHBlob.split(blob) else {
            throw SessionError.protocolViolation("the ssh-agent returned a malformed signature")
        }
        // The agent decides the signature algorithm, and it must match what was advertised — the server
        // checks. It can legitimately differ for RSA, where an agent may answer an `ssh-rsa` request with
        // `rsa-sha2-512`; that is a signature this transport cannot carry, and saying so beats sending a
        // blob whose two algorithm names disagree.
        guard split.algorithm == A.sshName else {
            throw SessionError.authenticationFailed(
                reason: "the ssh-agent signed with \(split.algorithm), which this SSH transport "
                    + "cannot offer. An Ed25519 key will work."
            )
        }
        return AgentSignature<A>(rawRepresentation: split.body)
    }
}

// MARK: - Building offers

extension SSHAgentClient {

    /// Turns the agent's identities into offers, skipping any algorithm this transport cannot carry.
    ///
    /// Skipping rather than failing is deliberate: an agent commonly holds keys of several kinds, and one
    /// unusable key — a FIDO `sk-ssh-ed25519`, a certificate, an old DSA key — should not stop the others
    /// from being tried.
    ///
    /// - Parameters:
    ///   - identities: What the agent reported, in its own order.
    ///   - limit: How many to offer at most. Defaults to 4, because every public key offer spends one of
    ///     the server's `MaxAuthTries` — six by default, three at some sites — and running that budget out
    ///     mid-chain looks like a dropped connection rather than a refusal.
    ///   - log: Where to report identities that were skipped or dropped.
    /// - Returns: Offers in the agent's order.
    func offers(
        from identities: [SSHAgentIdentity],
        limit: Int = 4,
        log: (String) -> Void = { _ in }
    ) -> [AuthenticationOffer] {
        var offers: [AuthenticationOffer] = []

        for identity in identities {
            guard offers.count < limit else {
                // Say so. A user with eight keys should learn why the ninth was never tried, rather than
                // seeing a bare refusal.
                log("Not offering \(identities.count - offers.count) further agent key(s): the server "
                    + "only allows a few attempts per connection.")
                break
            }
            guard let key = privateKey(for: identity) else {
                log("Skipping agent key \(identity.displayName): DriverPro cannot offer that algorithm.")
                continue
            }
            offers.append(.key(key, label: "agent key \(identity.displayName)"))
        }
        return offers
    }

    /// Wraps one identity as a NIOSSH key, or `nil` if its algorithm is not one we can carry.
    private func privateKey(for identity: SSHAgentIdentity) -> NIOSSHPrivateKey? {
        // One case per algorithm, because `keyPrefix` is static and so each needs its own type. The
        // absences are deliberate: `sk-*` (FIDO), `*-cert-v01@openssh.com` (certificates) and `ssh-dss`
        // are all things NIOSSH cannot express through a custom key.
        switch identity.algorithm {
        case Ed25519Agent.sshName:
            return AgentSignedKey<Ed25519Agent>(client: self, identity: identity).map(NIOSSHPrivateKey.init(custom:))
        case P256Agent.sshName:
            return AgentSignedKey<P256Agent>(client: self, identity: identity).map(NIOSSHPrivateKey.init(custom:))
        case P384Agent.sshName:
            return AgentSignedKey<P384Agent>(client: self, identity: identity).map(NIOSSHPrivateKey.init(custom:))
        case P521Agent.sshName:
            return AgentSignedKey<P521Agent>(client: self, identity: identity).map(NIOSSHPrivateKey.init(custom:))
        case RSAAgent.sshName:
            return AgentSignedKey<RSAAgent>(client: self, identity: identity).map(NIOSSHPrivateKey.init(custom:))
        default:
            return nil
        }
    }
}
