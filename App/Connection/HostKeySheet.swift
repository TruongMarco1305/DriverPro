//
//  HostKeySheet.swift
//  DriverPro
//

import DPCore
import DPPresentation
import SwiftUI

/// Asks whether to trust a server's identity.
///
/// An unknown key and a *changed* key are presented very differently. The first is routine — every
/// server is new once. The second may be an attack, so it is red, it says so, and it has no default
/// button: accepting has to be a deliberate click, not a reflexive Return.
struct HostKeySheet: View {

    @Environment(AppEnvironment.self) private var environment

    let challenge: HostKeyChallenge
    let host: RemoteHost

    private var hasChanged: Bool {
        if case .changed = challenge.trust { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                hasChanged ? "The server's identity has changed" : "Unknown server",
                systemImage: hasChanged ? "exclamationmark.triangle.fill" : "questionmark.circle"
            )
            .font(.headline)
            .foregroundStyle(hasChanged ? Color.red : Color.primary)

            Text(explanation)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    fingerprintRow("Fingerprint", challenge.fingerprint)
                    if case .changed(let previous) = challenge.trust {
                        Divider()
                        fingerprintRow("Previously", previous)
                    }
                    Divider()
                    HStack {
                        Text("Key type").foregroundStyle(.secondary)
                        Spacer()
                        Text(challenge.keyType).monospaced()
                    }
                }
                .font(.callout)
            }

            Text("Compare this with `ssh-keygen -lf` on the server before accepting.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Reject", role: .cancel) { environment.prompt.answerHostKey(.reject) }
                Spacer()
                Button("Accept Once") { environment.prompt.answerHostKey(.acceptOnce) }
                Button("Always Trust") { environment.prompt.answerHostKey(.acceptAndStore) }
                    // No default action on a changed key: accepting must be deliberate.
                    .keyboardShortcut(hasChanged ? .none : .defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var explanation: String {
        if hasChanged {
            return """
            The key for \(host.hostname) does not match the one recorded in known_hosts. Either the \
            server was rebuilt, or something is impersonating it. Do not accept unless you know why it \
            changed.
            """
        }
        return """
        \(host.hostname) has not been seen before. Accepting records its key so this is not asked again.
        """
    }

    private func fingerprintRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospaced().textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
    }
}
