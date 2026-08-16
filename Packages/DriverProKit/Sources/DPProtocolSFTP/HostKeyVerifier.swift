//
//  HostKeyVerifier.swift
//  DPProtocolSFTP
//

import Citadel
import DPCore
import DPCredentials
import Foundation
import NIOCore
import NIOSSH

/// Decides whether to trust a server's host key, consulting `known_hosts` and then a human.
///
/// This is the seam between two worlds that do not naturally meet.
///
/// **NIO's world** is callback-based. Its requirement is synchronous and settles a promise:
///
/// ```swift
/// func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>)
/// ```
///
/// It runs on an event loop thread, which must not be blocked — every other connection shares it.
///
/// **DriverPro's world** is `async`, because the answer may take thirty seconds while a person reads a
/// fingerprint and decides.
///
/// ## Swift note — bridging `async` code to a callback API
/// The bridge is to start a `Task` and settle the promise from inside it:
///
/// ```swift
/// func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise promise: EventLoopPromise<Void>) {
///     Task { …await…; promise.succeed(()) }   // returns immediately; the loop is never blocked
/// }
/// ```
///
/// The function returns straight away and the event loop carries on. Two rules make it safe:
///
/// 1. **The promise must be settled on every path** — success, refusal, thrown error, cancellation. An
///    unsettled `EventLoopPromise` means `connect` never returns and never fails: the connection hangs
///    forever with no error to report. That is why the whole body sits in a `do`/`catch` that fails the
///    promise for *any* error rather than only the expected ones.
/// 2. **Everything captured must be `Sendable`**, since the closure crosses threads. This type is a
///    `struct` of `Sendable` values, so the compiler verifies that rather than taking our word for it.
///
/// This is the canonical shape for wrapping any promise- or completion-handler API in Swift concurrency.
struct HostKeyVerifier: NIOSSHClientServerAuthenticationDelegate, Sendable {

    /// The connection being established, passed back to the delegate so prompts can name the server.
    let host: RemoteHost

    /// Where trusted keys are recorded.
    let knownHosts: KnownHostsStore

    /// Who to ask when a key is unknown or has changed.
    let delegate: any SessionDelegate

    /// Called by NIOSSH once the server has presented its host key.
    ///
    /// - Parameters:
    ///   - hostKey: The key the server offered.
    ///   - validationCompletePromise: Succeeded to accept the key, failed to refuse it. **Must** be
    ///     settled exactly once.
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // Serialise the key while still on the event loop: ByteBuffer is not Sendable, so the raw bytes
        // are extracted here and only `Data` crosses into the task.
        var buffer = ByteBuffer()
        hostKey.write(to: &buffer)
        let keyBlob = Data(buffer.readableBytesView)

        Task {
            do {
                try await decide(keyBlob: keyBlob)
                validationCompletePromise.succeed(())
            } catch {
                // Any error at all fails the promise. Letting one escape would leave the promise
                // unsettled and hang the connection with no diagnosis.
                validationCompletePromise.fail(error)
            }
        }
    }

    /// Works out whether the key is acceptable, asking the user if `known_hosts` cannot answer.
    ///
    /// - Parameter keyBlob: The server's key in wire format.
    /// - Throws: ``SessionError/hostKeyRejected`` if the key is revoked or the user declines.
    private func decide(keyBlob: Data) async throws {
        let trust = try await knownHosts.trust(host: host.hostname, port: host.port, keyBlob: keyBlob)

        switch trust {
        case .trusted:
            // Already on record. Connect silently — prompting for keys the user has accepted before is
            // what teaches people to dismiss the prompt without reading it.
            delegate.session(host, didLog: TranscriptMessage(
                direction: .local,
                text: "Host key verified against known_hosts."
            ))
            return

        case .revoked:
            // Never ask. A revoked key is a decision already made, and offering to override it would
            // undo the point of recording the revocation.
            delegate.session(host, didLog: TranscriptMessage(
                direction: .local,
                text: "Host key is marked @revoked in known_hosts. Refusing to connect."
            ))
            throw SessionError.hostKeyRejected

        case .unknown:
            try await ask(keyBlob: keyBlob, trust: .unknown)

        case .mismatch(let storedFingerprint):
            try await ask(keyBlob: keyBlob, trust: .changed(previousFingerprint: storedFingerprint))
        }
    }

    /// Puts the question to the user and acts on the answer.
    ///
    /// - Parameters:
    ///   - keyBlob: The server's key.
    ///   - trust: Whether the key is unknown or has changed, which the UI presents very differently.
    /// - Throws: ``SessionError/hostKeyRejected`` if the user declines.
    private func ask(keyBlob: Data, trust: HostKeyChallenge.Trust) async throws {
        let challenge = HostKeyChallenge(
            hostname: host.hostname,
            port: host.port,
            keyType: HostKeyFingerprint.algorithmName(ofKeyBlob: keyBlob) ?? "unknown",
            fingerprint: HostKeyFingerprint.sha256(ofKeyBlob: keyBlob),
            trust: trust
        )

        switch await delegate.session(host, needsHostKeyVerification: challenge) {
        case .reject:
            throw SessionError.hostKeyRejected

        case .acceptOnce:
            // Deliberately not recorded, so the question returns next time.
            return

        case .acceptAndStore:
            // A changed key is *appended* rather than replacing the old line, matching OpenSSH: the
            // previous entry stays visible in the file for the user to inspect or remove by hand.
            try await knownHosts.append(host: host.hostname, port: host.port, keyBlob: keyBlob)
            delegate.session(host, didLog: TranscriptMessage(
                direction: .local,
                text: "Host key added to \(knownHosts.fileURL.path)."
            ))
        }
    }
}
