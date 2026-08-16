//
//  SessionDelegate.swift
//  DPCore
//

import Foundation

// MARK: - Host key verification

/// A server's identity, presented for approval before the connection is trusted.
///
/// This is the moment that decides whether the user is talking to their server or to somebody sitting
/// between them and it. It is presented to a human because no algorithm can answer it.
public struct HostKeyChallenge: Hashable, Sendable {

    /// What is already known about this server's key.
    public enum Trust: Hashable, Sendable {
        /// Never seen before. Normal on a first connection: the user confirms the fingerprint out of band
        /// and the key is remembered. This is trust-on-first-use.
        case unknown

        /// A key is on record for this host and it does **not** match the one just offered.
        ///
        /// This is the serious one. It means either the server was legitimately rebuilt, or somebody is
        /// impersonating it. The UI must make the difference in gravity between this and ``unknown``
        /// obvious, and must never default to Accept.
        case changed(previousFingerprint: String)
    }

    /// The server address, for display.
    public var hostname: String
    /// The port connected to.
    public var port: Int
    /// The key algorithm, such as `"ssh-ed25519"` or `"rsa-sha2-512"`.
    public var keyType: String
    /// The key's SHA-256 fingerprint in OpenSSH's format, `"SHA256:qN0…"`, so it can be compared
    /// character-for-character against `ssh-keygen -lf` output.
    public var fingerprint: String
    /// Whether this key is unknown or has changed.
    public var trust: Trust

    /// Creates a host key challenge.
    ///
    /// - Parameters:
    ///   - hostname: The server address.
    ///   - port: The port connected to.
    ///   - keyType: The key algorithm name.
    ///   - fingerprint: SHA-256 fingerprint in OpenSSH format.
    ///   - trust: Whether the key is unknown or changed.
    public init(hostname: String, port: Int, keyType: String, fingerprint: String, trust: Trust) {
        self.hostname = hostname
        self.port = port
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.trust = trust
    }
}

/// The user's answer to a ``HostKeyChallenge``.
public enum HostKeyDecision: Hashable, Sendable {
    /// Refuse the connection. The session throws ``SessionError/hostKeyRejected``.
    case reject
    /// Proceed this once without recording the key, so the question returns next time.
    case acceptOnce
    /// Proceed and write the key to `known_hosts`.
    case acceptAndStore
}

// MARK: - Credential prompting

/// A request for credentials, made when none were stored or the stored ones were refused.
public struct CredentialRequest: Sendable {

    /// Why the session is asking.
    public enum Reason: Sendable {
        /// No credentials were available to begin with.
        case initial
        /// The server rejected the previous attempt. Carries the server's stated reason.
        case retry(afterFailure: String)
        /// A private key was found but is encrypted and needs its passphrase.
        case privateKeyPassphrase(keyPath: String)
    }

    /// The connection being established.
    public var host: RemoteHost
    /// Why credentials are needed.
    public var reason: Reason
    /// Whether the UI should offer a "remember in Keychain" checkbox.
    ///
    /// `false` for one-shot connections the user asked not to save.
    public var allowsPersistence: Bool

    /// Creates a credential request.
    ///
    /// - Parameters:
    ///   - host: The connection being established.
    ///   - reason: Why credentials are needed.
    ///   - allowsPersistence: Whether to offer saving to the Keychain.
    public init(host: RemoteHost, reason: Reason, allowsPersistence: Bool = true) {
        self.host = host
        self.reason = reason
        self.allowsPersistence = allowsPersistence
    }
}

// MARK: - Transcript

/// A line of protocol conversation, surfaced for the transcript window and logs.
public struct TranscriptMessage: Hashable, Sendable {
    /// Which way the message travelled.
    public enum Direction: Hashable, Sendable {
        /// Sent by DriverPro.
        case request
        /// Received from the server.
        case response
        /// Generated locally — a state change or diagnostic.
        case local
    }

    /// Which way the message travelled.
    public var direction: Direction
    /// The message text, already stripped of anything secret.
    public var text: String
    /// When it happened.
    public var timestamp: Date

    /// Creates a transcript message.
    ///
    /// - Parameters:
    ///   - direction: Which way it travelled.
    ///   - text: The message text. Must not contain passwords.
    ///   - timestamp: When it happened. Defaults to now.
    public init(direction: Direction, text: String, timestamp: Date = Date()) {
        self.direction = direction
        self.text = text
        self.timestamp = timestamp
    }
}

// MARK: - The delegate

/// How a backend asks a human a question.
///
/// Protocol implementations never present UI — that would put AppKit inside `DriverProKit` and destroy
/// the layering boundary. Instead they `await` a delegate call, and something above them decides how to
/// answer: a window in the real app, a canned response in a test.
///
/// ## Swift note — `async` protocol requirements
/// These methods are `async`, which is what makes the design work. A backend can *suspend* mid-handshake
/// for however long the user takes to read a fingerprint and click a button, without blocking a thread
/// and without callback nesting. The call site reads like straight-line code:
///
/// ```swift
/// let decision = await delegate.session(host, needsHostKeyVerification: challenge)
/// guard decision != .reject else { throw SessionError.hostKeyRejected }
/// ```
///
/// ## Swift note — `Sendable` on a protocol
/// Requiring `Sendable` means a delegate can be handed across task and actor boundaries safely. A UI
/// implementation will typically be a small `Sendable` value that hops to `@MainActor` internally, rather
/// than being a view controller itself.
public protocol SessionDelegate: Sendable {

    /// Asks whether to trust a server's host key.
    ///
    /// Called during the handshake, before authentication — a key that is not trusted must never be sent
    /// a password.
    ///
    /// - Parameters:
    ///   - host: The connection being established.
    ///   - challenge: The key being offered and what is known about it.
    /// - Returns: Whether to reject, accept once, or accept and remember.
    func session(_ host: RemoteHost, needsHostKeyVerification challenge: HostKeyChallenge) async -> HostKeyDecision

    /// Asks for credentials.
    ///
    /// - Parameters:
    ///   - host: The connection being established.
    ///   - request: Why credentials are needed.
    /// - Returns: The credentials to try, or `nil` if the user cancelled.
    func session(_ host: RemoteHost, needsCredentials request: CredentialRequest) async -> Credentials?

    /// Answers an SSH keyboard-interactive challenge, the usual carrier for one-time MFA codes.
    ///
    /// - Parameters:
    ///   - host: The connection being established.
    ///   - prompts: The server's questions, in order. Each is paired with whether the typed answer should
    ///     be echoed on screen — `false` for a password, `true` for something like a token serial number.
    /// - Returns: One answer per prompt, in the same order, or `nil` if the user cancelled.
    func session(
        _ host: RemoteHost,
        needsKeyboardInteractiveResponses prompts: [(prompt: String, isEchoed: Bool)]
    ) async -> [String]?

    /// Reports a line of protocol conversation.
    ///
    /// Called frequently and from arbitrary tasks, so implementations must be cheap and must not block.
    ///
    /// - Parameters:
    ///   - host: The connection the message belongs to.
    ///   - message: What was sent or received.
    func session(_ host: RemoteHost, didLog message: TranscriptMessage)
}

// MARK: - Default implementations

extension SessionDelegate {
    /// Refuses keyboard-interactive authentication by default.
    ///
    /// ## Swift note — protocol extensions as default implementations
    /// A method body in a protocol extension becomes the default for any conformer that does not supply
    /// its own. This is how a protocol can have many requirements while staying cheap to adopt: a test
    /// double implements the two methods it cares about and inherits the rest. Note the default is the
    /// *safe* answer — declining — rather than a guess at what the user would have said.
    public func session(
        _ host: RemoteHost,
        needsKeyboardInteractiveResponses prompts: [(prompt: String, isEchoed: Bool)]
    ) async -> [String]? {
        nil
    }

    /// Discards transcript messages by default.
    public func session(_ host: RemoteHost, didLog message: TranscriptMessage) {}
}
