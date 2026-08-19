//
//  CredentialSheet.swift
//  DriverPro
//

import DPCore
import DPPresentation
import SwiftUI

/// Asks for a secret, and says why it is asking.
///
/// The reason does more than pick a sentence: it decides what the one secure field *means*. For
/// `privateKeyPassphrase` the field is a key's passphrase rather than an account password, and the
/// user name is irrelevant, so it goes away. `CredentialCoordinator` converts the answer back — see
/// `CredentialRequest.Reason.privateKeyPassphrase`.
struct CredentialSheet: View {

    @Environment(AppEnvironment.self) private var environment

    let request: CredentialRequest

    @State private var username = ""
    @State private var secret = ""
    @State private var savesSecret = true

    /// Whether this sheet is unlocking a key rather than signing in to a server.
    private var isUnlockingKey: Bool {
        if case .privateKeyPassphrase = request.reason { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                if !isUnlockingKey {
                    TextField("User Name", text: $username)
                }
                SecureField(isUnlockingKey ? "Passphrase" : "Password", text: $secret)
                if request.allowsPersistence {
                    Toggle(isUnlockingKey ? "Remember passphrase in Keychain"
                                          : "Save password in Keychain", isOn: $savesSecret)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", role: .cancel) { environment.prompt.answerCredentials(nil) }
                Spacer()
                Button(isUnlockingKey ? "Unlock" : "Connect") {
                    environment.prompt.answerCredentials(.password(
                        username: username,
                        password: secret,
                        shouldPersist: request.allowsPersistence && savesSecret
                    ))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitDisabled)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { username = request.host.username ?? "" }
    }

    /// A key needs its passphrase; a server needs a user name. Requiring a user name for a passphrase
    /// would make the prompt unanswerable for a bookmark that has none.
    private var isSubmitDisabled: Bool {
        isUnlockingKey ? secret.isEmpty : username.isEmpty
    }

    private var title: String {
        switch request.reason {
        case .initial: "Sign in to \(request.host.hostname)"
        case .retry: "Login failed"
        case .privateKeyPassphrase: "Unlock private key"
        case .privateKeyUnreadable: "That key cannot be used"
        }
    }

    private var explanation: String {
        switch request.reason {
        case .initial:
            "Enter the password for \(request.host.hostname)."
        case .retry(let failure):
            // The server's own words. "Login failed" alone leaves the user guessing.
            "The server rejected the previous attempt: \(failure)"
        case .privateKeyPassphrase(let keyPath):
            "Enter the passphrase for \(keyPath)."
        case .privateKeyUnreadable(let keyPath, let reason):
            // Nothing reached the server. Naming the file is what lets the user go and fix it.
            "\(reason)\n\nDriverPro could not use \(keyPath). Sign in with a password instead, or "
                + "choose a different key by editing this connection."
        }
    }
}
