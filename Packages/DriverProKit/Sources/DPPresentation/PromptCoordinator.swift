//
//  PromptCoordinator.swift
//  DriverProKit
//
//  Target responsibility
//  ────────────────────
//  DPPresentation holds observable state and the logic behind it — sorting, filtering, navigation,
//  validation, and the bridge between the engine's async questions and a user interface.
//
//  It may import Foundation, Observation, and the DP engine targets. It may NOT import SwiftUI or
//  AppKit: it prepares state for a view without knowing what draws it, which is what keeps it testable
//  with `swift test`.
//
//  This is the one place in the package permitted to mention `@MainActor`. See docs/style.md.
//

import DPCore
import DPServices
import Foundation
import Observation

/// Turns the engine's `async` questions into observable state a view can present, and back again.
///
/// ## Swift note — bridging a sheet to an `async` caller
/// `UserPrompt` suspends until a human answers. SwiftUI does the opposite: it presents a sheet and
/// returns immediately. A continuation joins them —
///
/// ```swift
/// await withCheckedContinuation { continuation in
///     waiting.append(.hostKey(challenge, host, continuation))   // the view observes this
/// }
/// ```
///
/// — and the view resumes it on a button tap. Same shape as the `EventLoopPromise` bridge in
/// `HostKeyVerifier`, and the same fatal failure mode: **resume exactly once, on every path.** Never
/// resuming hangs the connection with no error to show; resuming twice traps.
///
/// Dismissing a sheet without choosing therefore has to mean something. Here it means cancel, which is
/// the safe answer for both questions: refuse the key, supply no credentials.
///
/// Questions queue rather than replace. A connection can ask about a host key and then for a password;
/// dropping the first would strand its continuation forever.
@MainActor
@Observable
public final class PromptCoordinator: UserPrompt {

    /// A question awaiting an answer.
    public enum Question: Identifiable, Sendable {
        /// The server's identity needs confirming.
        case hostKey(HostKeyChallenge, RemoteHost)
        /// Credentials are needed.
        case credentials(CredentialRequest)

        /// Stable identity for sheet presentation.
        public var id: String {
            switch self {
            case .hostKey(let challenge, _): "hostKey-\(challenge.fingerprint)"
            case .credentials(let request): "credentials-\(request.host.id)"
            }
        }
    }

    /// A question plus the continuation waiting on it.
    ///
    /// Kept as an enum with typed continuations rather than one erased closure, so answering a host key
    /// question with credentials cannot compile.
    private enum Waiting {
        case hostKey(HostKeyChallenge, RemoteHost, CheckedContinuation<HostKeyDecision, Never>)
        case credentials(CredentialRequest, CheckedContinuation<Credentials?, Never>)
    }

    private var waiting: [Waiting] = []

    /// Credentials typed before the engine asked for them, keyed by bookmark.
    private var preloaded: [UUID: Credentials] = [:]

    /// Creates an idle coordinator.
    public init() {}

    /// Supplies credentials in advance, so the connection sheet's password is used without a second
    /// prompt appearing over it.
    ///
    /// Consumed on first use: if the server rejects them, the retry reaches the user as it should.
    ///
    /// - Parameters:
    ///   - credentials: What the user typed.
    ///   - host: Which connection they belong to.
    public func preload(_ credentials: Credentials, for host: RemoteHost) {
        preloaded[host.id] = credentials
    }

    /// The question to show, or `nil` when nothing is being asked.
    ///
    /// Derived from the queue, so a view can drive a sheet from it directly.
    public var pending: Question? {
        switch waiting.first {
        case .hostKey(let challenge, let host, _): .hostKey(challenge, host)
        case .credentials(let request, _): .credentials(request)
        case nil: nil
        }
    }

    /// How many questions are outstanding. For tests and diagnostics.
    public var pendingCount: Int { waiting.count }

    // MARK: - UserPrompt

    /// Suspends until the user answers, publishing the question for a view to present.
    /// - Parameters:
    ///   - challenge: The key being offered.
    ///   - host: The connection being established.
    /// - Returns: What the user chose. A dismissed sheet counts as a refusal.
    public func askHostKey(_ challenge: HostKeyChallenge, for host: RemoteHost) async -> HostKeyDecision {
        await withCheckedContinuation { continuation in
            waiting.append(.hostKey(challenge, host, continuation))
        }
    }

    /// Suspends until the user answers, unless credentials were preloaded for a first attempt.
    /// - Parameter request: Why credentials are needed.
    /// - Returns: What to try, or `nil` if the user cancelled.
    public func askCredentials(_ request: CredentialRequest) async -> Credentials? {
        // Only for the first attempt. A retry means what we had was refused, so the user must see it.
        if case .initial = request.reason,
           let ready = preloaded.removeValue(forKey: request.host.id) {
            return ready
        }

        return await withCheckedContinuation { continuation in
            waiting.append(.credentials(request, continuation))
        }
    }

    // MARK: - Answering

    /// Answers a pending host key question.
    ///
    /// Ignored when the outstanding question is not about a host key, so a stale view cannot resume the
    /// wrong continuation.
    ///
    /// - Parameter decision: What the user chose.
    public func answerHostKey(_ decision: HostKeyDecision) {
        guard case .hostKey(_, _, let continuation)? = waiting.first else { return }
        waiting.removeFirst()
        continuation.resume(returning: decision)
    }

    /// Answers a pending credential question.
    ///
    /// - Parameter credentials: What the user supplied, or `nil` if they cancelled.
    public func answerCredentials(_ credentials: Credentials?) {
        guard case .credentials(_, let continuation)? = waiting.first else { return }
        waiting.removeFirst()
        continuation.resume(returning: credentials)
    }

    /// Treats the outstanding question as cancelled.
    ///
    /// What a dismissed sheet means. The answer is the safe one in both cases — refuse the key, supply
    /// nothing — because a user who closed the window without choosing has not consented to anything.
    public func dismiss() {
        switch waiting.first {
        case .hostKey(_, _, let continuation):
            waiting.removeFirst()
            continuation.resume(returning: .reject)
        case .credentials(_, let continuation):
            waiting.removeFirst()
            continuation.resume(returning: nil)
        case nil:
            break
        }
    }

    /// Cancels every outstanding question, in order.
    ///
    /// For teardown: a window closing while a connection is mid-handshake must not leave continuations
    /// suspended forever.
    public func dismissAll() {
        while !waiting.isEmpty { dismiss() }
    }
}
