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
    private let keys: PrivateKeyLocator

    /// Credentials the user asked to save, awaiting a successful connection.
    private var pending: [UUID: Credentials] = [:]

    /// Creates a coordinator.
    ///
    /// - Parameters:
    ///   - store: Where passwords and key passphrases are kept.
    ///   - prompt: How to reach the user when the store cannot answer.
    ///   - keys: How private key files are classified and read. Injected so tests can work in a
    ///     temporary directory rather than the real `~/.ssh`.
    public init(
        store: any CredentialStore,
        prompt: any UserPrompt,
        keys: PrivateKeyLocator = PrivateKeyLocator()
    ) {
        self.store = store
        self.prompt = prompt
        self.keys = keys
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

    /// Answers from the bookmark's chosen method first, the store second, and the user last.
    ///
    /// The bookmark decides *which* question to answer — see
    /// ``DPCore/RemoteHost/authenticationPreference``. That is why this is the only place in the engine
    /// that reads the preference: the session below is told what to use, and the sheet above is told
    /// what to ask, so neither has to know the rule.
    ///
    /// Only ``DPCore/CredentialRequest/Reason/initial`` consults anything stored. Every other reason
    /// means a previous answer was refused or unusable, and re-offering the same stored secret would
    /// loop.
    ///
    /// - Parameters:
    ///   - host: The connection being established.
    ///   - request: Why credentials are needed.
    /// - Returns: What to try, or `nil` if the user cancelled.
    public func session(
        _ host: RemoteHost,
        needsCredentials request: CredentialRequest
    ) async -> Credentials? {
        guard case .initial = request.reason else { return await ask(request, for: host) }

        switch host.authenticationPreference {
        case .password:
            if let username = host.username, let stored = try? await store.password(for: host) {
                // The whole point: a saved password connects with no prompt at all. `shouldPersist` is
                // false because it is already stored — re-saving it on every connect would be pointless
                // writes to the Keychain.
                return .password(username: username, password: stored)
            }
            return await ask(request, for: host)

        case .privateKey(let path):
            return await privateKeyCredentials(at: path, for: host, allowsPersistence: request.allowsPersistence)

        case .agent:
            // Nothing to look up and nothing to ask: the agent holds the key, and whether it will
            // actually sign for this server is only knowable by trying.
            return .sshAgent(username: username(for: host))
        }
    }

    /// Puts a question to the user, remembering the answer if they asked for it to be saved.
    private func ask(_ request: CredentialRequest, for host: RemoteHost) async -> Credentials? {
        guard let supplied = await prompt.askCredentials(request) else { return nil }
        if supplied.shouldPersist { pending[host.id] = supplied }
        return supplied
    }

    /// The account name to authenticate as.
    ///
    /// Falls back to the local account name, which is what `ssh` does when a host has no `User` — and
    /// for key and agent logins there is no prompt in the way to ask.
    private func username(for host: RemoteHost) -> String {
        if let username = host.username, !username.isEmpty { return username }
        return NSUserName()
    }

    // MARK: - Private key

    /// Builds a private key credential, prompting for a passphrase only if one is needed and unknown.
    ///
    /// The order matters. The key is *classified* before it is read, so the question "does this need a
    /// passphrase?" is settled — possibly by asking a human, which takes as long as a human takes —
    /// before any key material is sitting in memory waiting.
    private func privateKeyCredentials(
        at path: String,
        for host: RemoteHost,
        allowsPersistence: Bool
    ) async -> Credentials? {
        let key: PrivateKeyLocator.DiscoveredKey
        let data: Data
        do {
            key = try keys.inspectKey(at: URL(fileURLWithPath: path))
            data = try keys.read(key)
        } catch {
            // Nothing reached the server, so this is not a retry. Say what is wrong with the file and
            // let the user log in another way rather than reporting a bare authentication failure.
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return await ask(
                CredentialRequest(host: host, reason: .privateKeyUnreadable(keyPath: path, reason: reason),
                                  allowsPersistence: allowsPersistence),
                for: host
            )
        }

        guard key.isEncrypted else {
            return .privateKey(username: username(for: host), data: data, path: path)
        }

        if let stored = try? await store.passphrase(forPrivateKeyAt: path) {
            // The private-key twin of "a saved password connects with no prompt at all".
            return .privateKey(username: username(for: host), data: data, passphrase: stored, path: path)
        }

        let request = CredentialRequest(host: host, reason: .privateKeyPassphrase(keyPath: path),
                                        allowsPersistence: allowsPersistence)
        guard let answer = await prompt.askCredentials(request),
              case .password(let passphrase) = answer.method else { return nil }

        // The sheet has one secret field, and the question it was asked establishes what that field
        // means. Reinterpreting it happens here and nowhere else — the session only sees `.privateKey`.
        let credentials = Credentials.privateKey(
            username: username(for: host), data: data, passphrase: passphrase, path: path,
            shouldPersist: answer.shouldPersist
        )
        if credentials.shouldPersist { pending[host.id] = credentials }
        return credentials
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
    /// Failing to save is not worth failing a working connection over, so a store error is swallowed
    /// here rather than thrown.
    ///
    /// The `switch` is exhaustive on purpose. This used to be a `guard case .password`, which meant a
    /// passphrase the user asked to remember was dropped without a word — and a future `.token` would
    /// have been dropped just as quietly. Listing every case forces the next method added to say what
    /// happens to it.
    ///
    /// - Parameter host: The connection that just succeeded.
    public func persistPending(for host: RemoteHost) async {
        guard let credentials = pending.removeValue(forKey: host.id) else { return }

        switch credentials.method {
        case .password(let password):
            try? await store.setPassword(password, for: host)

        case .privateKey(_, .some(let passphrase), .some(let path)):
            // Keyed by the key's path, not by the bookmark: one key may unlock several connections,
            // and OpenSSH's own Keychain integration addresses it the same way.
            try? await store.setPassphrase(passphrase, forPrivateKeyAt: path)

        case .privateKey, .sshAgent, .anonymous, .token:
            // An unencrypted key has no secret to keep; the agent holds its own; anonymous has none;
            // a token's lifetime is the server's business, not ours.
            break
        }
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
