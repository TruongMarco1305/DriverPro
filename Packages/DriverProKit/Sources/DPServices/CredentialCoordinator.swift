//
//  CredentialCoordinator.swift
//  DPServices
//

import DPCore
import DPCredentials
import Foundation

/// Answers a session's questions from the credential store first, and the user second.
///
/// This is where "reconnect from a saved bookmark without retyping a password" actually happens: a
/// stored password is returned without the prompt ever being consulted.
///
/// ## Why saving is not done here
/// A password is only worth keeping once the server has accepted it. Saving at prompt time stores
/// whatever was typed — including a typo — producing a bookmark that silently fails forever and cannot
/// be fixed without knowing to delete a Keychain item.
///
/// A `SessionDelegate` cannot see whether the connection succeeded; it is asked a question and answers.
/// So credentials the user asked to save are held here as *pending*, and
/// ``DriverProServices/connect(to:)`` calls ``persistPending(for:)`` once the connection is up, or
/// ``discardPending(for:)`` when it is not.
public actor CredentialCoordinator: SessionDelegate {

    private let store: any CredentialStore
    private let prompt: any UserPrompt

    /// Credentials the user asked to save, awaiting a successful connection.
    private var pending: [UUID: Credentials] = [:]

    /// Creates a coordinator.
    ///
    /// - Parameters:
    ///   - store: Where passwords are kept.
    ///   - prompt: How to reach the user when the store cannot answer.
    public init(store: any CredentialStore, prompt: any UserPrompt) {
        self.store = store
        self.prompt = prompt
    }

    // MARK: - SessionDelegate

    /// Forwards to the user.
    ///
    /// No `known_hosts` lookup here: `HostKeyVerifier` in `DPProtocolSFTP` already consults it and only
    /// asks the delegate when the key is unknown or has changed. Checking again would either duplicate
    /// that logic or contradict it.
    public func session(
        _ host: RemoteHost,
        needsHostKeyVerification challenge: HostKeyChallenge
    ) async -> HostKeyDecision {
        await prompt.askHostKey(challenge, for: host)
    }

    /// Tries the credential store, then the user.
    ///
    /// - Parameters:
    ///   - host: The connection being established.
    ///   - request: Why credentials are needed.
    /// - Returns: What to try, or `nil` if the user cancelled.
    public func session(
        _ host: RemoteHost,
        needsCredentials request: CredentialRequest
    ) async -> Credentials? {
        if case .initial = request.reason,
           let username = host.username,
           let stored = try? await store.password(for: host) {
            // The whole point: a saved password connects with no prompt at all. `shouldPersist` is
            // false because it is already stored — re-saving it on every connect would be pointless
            // writes to the Keychain.
            return .password(username: username, password: stored)
        }

        guard let supplied = await prompt.askCredentials(request) else { return nil }
        if supplied.shouldPersist { pending[host.id] = supplied }
        return supplied
    }

    /// Forwards MFA challenges to the user.
    public func session(
        _ host: RemoteHost,
        needsKeyboardInteractiveResponses prompts: [(prompt: String, isEchoed: Bool)]
    ) async -> [String]? {
        await prompt.askKeyboardInteractive(prompts, for: host)
    }

    // MARK: - Persistence

    /// Saves credentials the user asked to keep, now that the server has accepted them.
    ///
    /// Only passwords are stored; a private key lives on disk and its passphrase is handled separately.
    /// Failing to save is not worth failing a working connection over, so a store error is swallowed
    /// here rather than thrown.
    ///
    /// - Parameter host: The connection that just succeeded.
    public func persistPending(for host: RemoteHost) async {
        guard let credentials = pending.removeValue(forKey: host.id) else { return }
        guard case .password(let password) = credentials.method else { return }
        try? await store.setPassword(password, for: host)
    }

    /// Forgets credentials for a connection that did not succeed.
    ///
    /// - Parameter host: The connection that failed.
    public func discardPending(for host: RemoteHost) {
        pending[host.id] = nil
    }

    /// Whether anything is waiting to be saved. For tests and diagnostics.
    /// - Parameter host: The connection to check.
    public func hasPending(for host: RemoteHost) -> Bool {
        pending[host.id] != nil
    }
}
