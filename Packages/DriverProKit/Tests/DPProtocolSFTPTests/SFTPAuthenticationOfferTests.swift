//
//  SFTPAuthenticationOfferTests.swift
//  DPProtocolSFTPTests
//

import Citadel
import Crypto
import DPCore
import Foundation
import NIOCore
import NIOEmbedded
import Testing
@preconcurrency import NIOSSH
@testable import DPProtocolSFTP

/// The offer chain, exercised without a server or a socket.
///
/// `EmbeddedEventLoop` is NIO's synchronous test loop: promises made on it complete immediately, so a
/// delegate written for callbacks can be driven a step at a time and inspected between steps. That is
/// what makes the ordering rules below assertable at all — against a real server they would only show up
/// as "it connected" or "it did not".
@Suite("SFTP authentication offers")
struct SFTPAuthenticationOfferTests {

    private let loop = EmbeddedEventLoop()

    /// A throwaway key, so an offer can be a real one rather than a stand-in.
    private func anyKey() -> NIOSSHPrivateKey {
        NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    }

    /// Asks the delegate for one offer and hands back its label, or `nil` if it refused to make one.
    private func nextLabel(
        from delegate: SFTPAuthenticationDelegate,
        available: NIOSSHAvailableUserAuthenticationMethods = .all
    ) -> String? {
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: available, nextChallengePromise: promise)

        // The offer itself carries no label, so what is asserted is the delegate's own record of what it
        // just offered — which is also exactly what a failure message is built from.
        guard (try? promise.futureResult.wait()) != nil else { return nil }
        return delegate.attempted.last
    }

    // MARK: - Order

    @Test("Offers are made in the order they were given")
    func offersKeepTheirOrder() {
        // Agent identities first, then a key file, then a password: strongest and least interactive
        // first, so the user is only asked for something typed when nothing else worked.
        let delegate = SFTPAuthenticationDelegate(username: "duck", offers: [
            .key(anyKey(), label: "agent key one"),
            .key(anyKey(), label: "agent key two"),
            .password("hunter2"),
        ])

        #expect(nextLabel(from: delegate) == "agent key one")
        #expect(nextLabel(from: delegate) == "agent key two")
        #expect(nextLabel(from: delegate) == "the password")
        #expect(delegate.attempted == ["agent key one", "agent key two", "the password"])
    }

    @Test("Running out of offers fails the promise, which is what reports a refused login")
    func exhaustionFailsThePromise() {
        let delegate = SFTPAuthenticationDelegate(username: "duck", offers: [.password("hunter2")])
        #expect(nextLabel(from: delegate) == "the password")

        // Succeeding with `nil` would leave NIOSSH to report a bare failure. Failing produces
        // `allAuthenticationOptionsFailed`, which `SFTPErrorMapping` already translates.
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .all, nextChallengePromise: promise)
        #expect(throws: SSHClientError.allAuthenticationOptionsFailed) {
            try promise.futureResult.wait()
        }
    }

    @Test("A delegate with nothing to offer fails immediately rather than hanging")
    func noOffersFailsAtOnce() {
        let delegate = SFTPAuthenticationDelegate(username: "duck", offers: [])
        #expect(nextLabel(from: delegate) == nil)
    }

    // MARK: - Filtering

    @Test("An offer the server will not accept is skipped, not spent")
    func skipsWhatTheServerRefuses() {
        // The reason this matters: Citadel filters offers itself, but not for `.custom` — it hands the
        // call straight through. And every attempt costs one of the server's `MaxAuthTries`, six by
        // default, so sending a password to a keys-only server wastes a slot and reports nothing useful.
        let delegate = SFTPAuthenticationDelegate(username: "duck", offers: [
            .password("hunter2"),
            .key(anyKey(), label: "agent key"),
        ])

        #expect(nextLabel(from: delegate, available: .publicKey) == "agent key")
        #expect(delegate.attempted == ["agent key"], "the password was never offered")
        #expect(delegate.skipped == ["the password"])
    }

    @Test("When everything is skipped the failure records what the server would not take")
    func skippingEverythingIsStillRecorded() {
        let delegate = SFTPAuthenticationDelegate(username: "duck", offers: [.password("hunter2")])

        #expect(nextLabel(from: delegate, available: .publicKey) == nil)
        #expect(delegate.attempted.isEmpty)
        #expect(delegate.skipped == ["the password"])
    }

    @Test("The first call is unfiltered, because the server has not said anything yet")
    func theFirstCallIsUnfiltered() {
        // NIOSSH passes `.all` before any refusal. If the filter treated that as "nothing allowed",
        // every login would fail before it started — so this is worth pinning down.
        let delegate = SFTPAuthenticationDelegate(username: "duck", offers: [.password("hunter2")])
        #expect(nextLabel(from: delegate, available: .all) == "the password")
    }

    // MARK: - Transcript

    @Test("Each offer is logged, and no log line contains the secret")
    func offersAreLoggedWithoutSecrets() {
        let lines = NIOLockedBox<[String]>([])
        let delegate = SFTPAuthenticationDelegate(
            username: "duck",
            offers: [.password("hunter2"), .key(anyKey(), label: "agent key")],
            log: { lines.append($0) }
        )

        _ = nextLabel(from: delegate)
        _ = nextLabel(from: delegate)

        #expect(lines.value.count == 2)
        #expect(lines.value.allSatisfy { !$0.contains("hunter2") },
                "a transcript is written to a log and shown in a window")
    }
}

/// What a refused login is allowed to say. SSH never says *why*, so this is the only source of detail.
@Suite("Explaining a refused login")
struct PreparedAuthenticationTests {

    private func anyMethod() -> SSHAuthenticationMethod {
        .passwordBased(username: "duck", password: "hunter2")
    }

    @Test("An error that is not an authentication failure is passed through untouched")
    func leavesOtherErrorsAlone() {
        let prepared = PreparedAuthentication(method: anyMethod(), includesRSAKey: true)
        let original = SessionError.unreachable(host: "example.com", reason: "connection refused")
        #expect(prepared.explain(original) == original)
    }

    @Test("A refused login keeps the server's own words")
    func keepsTheOriginalReason() {
        let prepared = PreparedAuthentication(method: anyMethod())
        let explained = prepared.explain(.authenticationFailed(reason: "the server rejected the credentials"))

        guard case .authenticationFailed(let reason) = explained else {
            Issue.record("expected an authentication failure")
            return
        }
        #expect(reason.contains("the server rejected the credentials"))
    }

    @Test("A refused login lists what was offered, so the user knows what was tried")
    func namesWhatWasOffered() throws {
        let loop = EmbeddedEventLoop()
        let chain = SFTPAuthenticationDelegate(username: "duck", offers: [
            .key(NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()), label: "agent key one"),
            .password("hunter2"),
        ])
        // Spend both offers, so the chain has a record to report.
        for _ in 0..<2 {
            let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
            chain.nextAuthenticationType(availableMethods: .all, nextChallengePromise: promise)
            _ = try promise.futureResult.wait()
        }

        let prepared = PreparedAuthentication(method: anyMethod(), chain: chain)
        guard case .authenticationFailed(let reason) =
            prepared.explain(.authenticationFailed(reason: "refused")) else {
            Issue.record("expected an authentication failure")
            return
        }
        #expect(reason.contains("agent key one"))
        #expect(reason.contains("the password"))
    }

    @Test("An RSA key that was refused says why RSA is likely the reason")
    func explainsTheRSADeadEnd() {
        // The transport can only sign RSA as `ssh-rsa`, which is SHA-1, which OpenSSH 8.8 and later
        // refuse by default. Without this the user sees "authentication failed" for a key that is
        // correctly installed on the server, and has no way to work out why.
        let prepared = PreparedAuthentication(method: anyMethod(), includesRSAKey: true)
        guard case .authenticationFailed(let reason) =
            prepared.explain(.authenticationFailed(reason: "refused")) else {
            Issue.record("expected an authentication failure")
            return
        }
        #expect(reason.contains("RSA"))
        #expect(reason.contains("Ed25519"), "a message with no way forward is only half a message")
    }

    @Test("A refused login with no RSA key involved does not mention RSA")
    func staysQuietAboutRSAOtherwise() {
        let prepared = PreparedAuthentication(method: anyMethod())
        guard case .authenticationFailed(let reason) =
            prepared.explain(.authenticationFailed(reason: "refused")) else {
            Issue.record("expected an authentication failure")
            return
        }
        #expect(!reason.contains("RSA"))
    }
}

/// A tiny thread-safe box, because the log callback is `@Sendable` and fires on another thread.
private final class NIOLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value { lock.withLock { storage } }
}

extension NIOLockedBox where Value == [String] {
    func append(_ line: String) { lock.withLock { storage.append(line) } }
}
