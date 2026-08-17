//
//  CredentialSheet.swift
//  DriverPro
//

import DPCore
import DPPresentation
import SwiftUI

/// Asks for a password, and says why it is asking.
struct CredentialSheet: View {

    @Environment(AppEnvironment.self) private var environment

    let request: CredentialRequest

    @State private var username = ""
    @State private var password = ""
    @State private var savesPassword = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("User Name", text: $username)
                SecureField("Password", text: $password)
                if request.allowsPersistence {
                    Toggle("Save password in Keychain", isOn: $savesPassword)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", role: .cancel) { environment.prompt.answerCredentials(nil) }
                Spacer()
                Button("Connect") {
                    environment.prompt.answerCredentials(.password(
                        username: username,
                        password: password,
                        shouldPersist: request.allowsPersistence && savesPassword
                    ))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(username.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { username = request.host.username ?? "" }
    }

    private var title: String {
        if case .retry = request.reason { return "Login failed" }
        return "Sign in to \(request.host.hostname)"
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
        }
    }
}
