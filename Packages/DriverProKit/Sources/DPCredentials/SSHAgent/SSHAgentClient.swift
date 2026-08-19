//
//  SSHAgentClient.swift
//  DPCredentials
//

import Foundation

// MARK: - Identity

/// One key an ssh-agent holds on our behalf.
///
/// Note what is absent: the key. An agent hands out its public keys and will sign with the private ones,
/// but never releases them — which is the entire reason to use one, and why this type is safe to log,
/// print, and show in a list.
public struct SSHAgentIdentity: Hashable, Sendable {

    /// The public key blob, byte for byte as the agent reported it.
    ///
    /// Not re-encoded, ever. The agent identifies a key by these exact bytes when asked to sign, so a
    /// round trip through any other representation risks producing something it will not match.
    public var keyBlob: Data

    /// The agent's own label for the key — what `ssh-add -l` shows, usually the file it was added from.
    public var comment: String

    /// Creates an identity.
    ///
    /// - Parameters:
    ///   - keyBlob: The public key blob as the agent reported it.
    ///   - comment: The agent's label for the key.
    public init(keyBlob: Data, comment: String) {
        self.keyBlob = keyBlob
        self.comment = comment
    }

    /// The key's algorithm, read out of the blob itself, such as `"ssh-ed25519"`.
    ///
    /// From the blob rather than from ``comment``, because the comment is free text the user chose and
    /// says nothing reliable about the algorithm.
    public var algorithm: String? {
        HostKeyFingerprint.algorithmName(ofKeyBlob: keyBlob)
    }

    /// The key's SHA-256 fingerprint, in the same form as `ssh-add -l`.
    public var fingerprint: String {
        HostKeyFingerprint.sha256(ofKeyBlob: keyBlob)
    }

    /// A short description for a transcript line or a failure message. Contains nothing secret.
    public var displayName: String {
        let algorithm = algorithm ?? "unknown"
        return comment.isEmpty ? algorithm : "\(comment) (\(algorithm))"
    }
}

// MARK: - Client

/// Asks the running ssh-agent what it holds, and asks it to sign.
///
/// ## Why this is synchronous, and a `struct`
///
/// Everything else in the engine that does I/O is an `actor` with `async` methods. This is not, and the
/// reason comes from outside: NIOSSH signs a public key offer through
/// `NIOSSHPrivateKeyProtocol.signature(for:)`, which is a **synchronous** function called on the
/// channel's event loop. There is no `await` available inside it, and the payload cannot be signed ahead
/// of time because it includes the session identifier from a handshake that has not finished yet.
///
/// So the agent round trip has to block. Given that, an `actor` would be worse than useless — it would
/// force `async` on an API whose one caller cannot use it. A `struct` holding nothing but a transport is
/// trivially `Sendable` for the honest reason that there is no state to protect.
///
/// The blocking is real and is bounded three ways: the transport's socket timeout, one exchange per
/// authentication attempt rather than per operation, and `SFTPSession` giving an agent connection its own
/// event loop so a Touch ID prompt cannot stall unrelated transfers.
public struct SSHAgentClient: Sendable {

    private let transport: any SSHAgentTransport

    /// The environment variable OpenSSH uses to advertise a running agent.
    public static let socketEnvironmentKey = "SSH_AUTH_SOCK"

    /// Creates a client over any transport. Used by tests to answer with canned bytes.
    /// - Parameter transport: How to exchange messages with the agent.
    public init(transport: any SSHAgentTransport) {
        self.transport = transport
    }

    /// Creates a client for the agent named by the environment, or `nil` if there is no agent.
    ///
    /// Returning `nil` rather than throwing is the useful shape here: "is there an agent?" is a question
    /// the connection sheet asks in order to grey out a menu item, and no agent is an ordinary state of
    /// the world rather than a failure.
    ///
    /// - Parameters:
    ///   - environment: Where to look. Defaults to this process's environment.
    ///   - timeout: Send and receive timeout for each exchange.
    public init?(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 20
    ) {
        guard let path = environment[Self.socketEnvironmentKey], !path.isEmpty else { return nil }
        self.transport = UnixSocketAgentTransport(socketPath: path, timeout: timeout)
    }

    /// Every key the agent currently holds.
    ///
    /// - Returns: The identities in the agent's own order, which is the order they were added and the
    ///   order OpenSSH would try them in.
    /// - Throws: ``CredentialError/agent(reason:)`` if the agent cannot be reached or refuses.
    public func identities() throws -> [SSHAgentIdentity] {
        try SSHAgentWire.identities(from: transport.exchange(SSHAgentWire.requestIdentities()))
    }

    /// Asks the agent to sign, using one of its keys.
    ///
    /// - Parameters:
    ///   - data: The bytes to sign.
    ///   - identity: Which key to use.
    ///   - flags: Signature options, such as ``SSHAgentWire/rsaSHA2_512``. Zero for the default.
    /// - Returns: The signature blob: an algorithm name, then the signature body.
    /// - Throws: ``CredentialError/agent(reason:)`` if the agent refuses — which is normal if it has been
    ///   locked, or if the key has been removed since ``identities()`` was called.
    public func signature(
        for data: Data,
        using identity: SSHAgentIdentity,
        flags: UInt32 = 0
    ) throws -> Data {
        let request = SSHAgentWire.signRequest(keyBlob: identity.keyBlob, data: data, flags: flags)
        return try SSHAgentWire.signature(from: transport.exchange(request))
    }
}
