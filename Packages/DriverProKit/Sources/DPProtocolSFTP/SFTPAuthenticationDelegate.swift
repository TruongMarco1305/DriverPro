//
//  SFTPAuthenticationDelegate.swift
//  DPProtocolSFTP
//

import Citadel
import DPCore
import Foundation
import NIOConcurrencyHelpers
import NIOCore

// ## Swift note — `@preconcurrency import`
//
// `NIOSSHUserAuthenticationOffer` is not marked `Sendable`, and handing one to an `EventLoopPromise`
// crosses an isolation boundary — which under Swift 6's language mode is an error, not a warning.
//
// The offer is genuinely safe here: it is built inside `nextAuthenticationType` and handed straight to
// the promise NIOSSH gave us, on NIOSSH's own event loop, and nothing else ever sees it. The type simply
// predates strict concurrency and has never been audited for it.
//
// `@preconcurrency import` is the tool for exactly this situation: it downgrades `Sendable`-related
// diagnostics *from this module only* to warnings, leaving every check on our own code intact. It is a
// narrower instrument than `@unchecked Sendable` — it makes no claim about any type, it just declines to
// treat an unaudited library as if it had opinions about concurrency. If the fork ever adopts strict
// concurrency, deleting the attribute is how we find out whether it worked. See ADR 009 for why the
// transport is a fork in the first place.
@preconcurrency import NIOSSH

/// One thing DriverPro is willing to try, and what the server must accept for it to be worth trying.
///
/// The offer itself is opaque here on purpose: a key offer looks identical whether the key came off
/// disk or is being signed by `ssh-agent`, so the delegate never has to know which.
struct AuthenticationOffer {

    /// What to call this in a transcript line or a failure message — "the password", "agent key
    /// `id_ed25519 (work laptop)`". Never anything secret.
    let label: String

    /// The server-advertised method this offer needs. An offer the server will not accept is skipped
    /// rather than spent, because every attempt costs one of the server's `MaxAuthTries`.
    let requires: NIOSSHAvailableUserAuthenticationMethods

    /// The offer as NIOSSH wants it.
    let offer: NIOSSHUserAuthenticationOffer.Offer

    /// A password offer.
    static func password(_ password: String) -> AuthenticationOffer {
        AuthenticationOffer(
            label: "the password",
            requires: .password,
            offer: .password(.init(password: password))
        )
    }

    /// A public key offer, from a file or from an agent.
    static func key(_ key: NIOSSHPrivateKey, label: String) -> AuthenticationOffer {
        AuthenticationOffer(
            label: label,
            requires: .publicKey,
            offer: .privateKey(.init(privateKey: key))
        )
    }
}

/// What to offer the server, plus enough context to explain a refusal afterwards.
///
/// The explanation is the reason this is a type rather than just an `SSHAuthenticationMethod`. SSH does
/// not say *why* it refused a login — only that every method it was willing to try is exhausted — so the
/// only party that can turn "authentication failed" into something a user can act on is the code that
/// knows what was offered. That knowledge is here.
///
/// Not `Sendable`: `SSHAuthenticationMethod` is a Citadel class that is not marked `Sendable`. Values of
/// this type never leave the actor that made them.
struct PreparedAuthentication {

    /// What Citadel should use.
    let method: SSHAuthenticationMethod

    /// The offer chain, when one was built. `nil` when a single stock Citadel factory was enough.
    let chain: SFTPAuthenticationDelegate?

    /// Whether an RSA key was among the offers, which changes what a refusal probably means.
    let includesRSAKey: Bool

    init(method: SSHAuthenticationMethod, chain: SFTPAuthenticationDelegate? = nil, includesRSAKey: Bool = false) {
        self.method = method
        self.chain = chain
        self.includesRSAKey = includesRSAKey
    }

    /// Adds what was tried to an authentication failure, leaving every other error alone.
    ///
    /// - Parameter error: The error the connection attempt produced.
    /// - Returns: The same error, with a fuller reason when it was a refused login.
    func explain(_ error: SessionError) -> SessionError {
        guard case .authenticationFailed(let reason) = error else { return error }

        var sentences = [reason]
        if let attempted = chain?.attempted, !attempted.isEmpty {
            sentences.append("DriverPro offered \(attempted.joined(separator: ", ")).")
        }
        if includesRSAKey {
            sentences.append(Self.rsaAdvice)
        }
        return .authenticationFailed(reason: sentences.joined(separator: " "))
    }

    /// Why an RSA key very likely failed, whatever the server's reason was.
    ///
    /// The SSH transport DriverPro is pinned to can only sign RSA keys as `ssh-rsa`, which means SHA-1;
    /// OpenSSH 8.8 (2021) disabled that by default. The modern replacements, `rsa-sha2-256` and
    /// `rsa-sha2-512`, cannot be expressed through this transport at all — the reasons and the exit
    /// criteria are in `docs/decisions/014-rsa-public-key-authentication-is-unavailable.md`. The user
    /// does not need the mechanism, only the way out, so the message names Ed25519 and stops there.
    static let rsaAdvice = """
        This is an RSA key, and RSA keys can only be signed with SHA-1 here, which OpenSSH 8.8 and \
        later reject by default. An Ed25519 key will work where this one cannot.
        """
}

/// Offers credentials to the server one at a time, in order, until one is accepted.
///
/// Citadel's own factories — `.passwordBased`, `.ed25519`, and the rest — each build a list of exactly
/// one offer, so a connection made through them gets a single attempt. That is not enough once
/// `ssh-agent` is involved: an agent commonly holds several identities and there is no way to know from
/// the outside which one a given server will accept, so they have to be tried. `.custom(_:)` is the only
/// route Citadel provides to a multi-offer chain, and this is that custom delegate.
///
/// Two behaviours are load-bearing and easy to lose:
///
/// - **Offers are filtered against what the server advertises.** Citadel's stock implementation does
///   this itself, but it does *not* do it for `.custom`, which hands the whole call through untouched.
///   Filtering here is therefore not a nicety; without it a password offer is sent to a server that
///   said it takes only public keys, which wastes an attempt and reports a confusing failure.
/// - **Exhaustion fails the promise rather than passing `nil`.** Failing produces
///   `SSHClientError.allAuthenticationOptionsFailed`, which `SFTPErrorMapping` already knows how to
///   translate. Returning `nil` would make NIOSSH report generic authentication failure with nothing
///   attached about what happened.
///
/// ## Swift note — `@unchecked Sendable`, and why this one needs a lock
/// `CitadelHandles.swift` also uses `@unchecked Sendable`, but for a different reason: those types wrap
/// a value only ever touched from inside an actor. This type genuinely has mutable state, and it is
/// touched from two places — NIOSSH calls ``nextAuthenticationType(availableMethods:nextChallengePromise:)``
/// on the channel's event loop, and `SFTPSession` reads ``attempted`` afterwards to explain a failure.
/// Those are different threads. `NIOLockedValueBox` is a small lock-guarded box; using it means the
/// promise in `@unchecked` is kept by the compiler-checked lock rather than by an argument about
/// ordering that a later refactor could quietly invalidate.
final class SFTPAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {

    /// What the delegate has done so far. Boxed because it is read from another thread.
    private struct Progress {
        var next = 0
        var attempted: [String] = []
        var skipped: [String] = []
    }

    private let username: String
    private let offers: [AuthenticationOffer]
    private let log: @Sendable (String) -> Void
    private let progress = NIOLockedValueBox(Progress())

    /// Creates a delegate.
    ///
    /// - Parameters:
    ///   - username: The account to authenticate as. The same for every offer — SSH settles the user
    ///     name once, not per attempt.
    ///   - offers: What to try, in order.
    ///   - log: Where to send a line per offer, for the transcript.
    init(
        username: String,
        offers: [AuthenticationOffer],
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.username = username
        self.offers = offers
        self.log = log
    }

    /// The offers actually made, in order, for a failure message.
    var attempted: [String] { progress.withLockedValue { $0.attempted } }

    /// Offers the server would not have accepted, so they were never sent.
    var skipped: [String] { progress.withLockedValue { $0.skipped } }

    /// Hands NIOSSH the next credential to try, or fails once there are none left.
    ///
    /// - Parameters:
    ///   - availableMethods: What the server said it accepts. On the very first call NIOSSH passes
    ///     `.all`, because nothing has been refused yet and the server has not yet said.
    ///   - nextChallengePromise: Where the offer goes.
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let next: AuthenticationOffer? = progress.withLockedValue { progress in
            while progress.next < offers.count {
                let candidate = offers[progress.next]
                progress.next += 1

                guard availableMethods.contains(candidate.requires) else {
                    progress.skipped.append(candidate.label)
                    continue
                }
                progress.attempted.append(candidate.label)
                return candidate
            }
            return nil
        }

        guard let next else {
            let skipped = self.skipped
            if !skipped.isEmpty {
                log("The server would not accept \(skipped.joined(separator: ", ")).")
            }
            nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
            return
        }

        log("Offering \(next.label).")
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: next.offer)
        )
    }
}
