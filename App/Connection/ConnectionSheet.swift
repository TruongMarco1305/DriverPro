//
//  ConnectionSheet.swift
//  DriverPro
//

import DPCore
import DPPresentation
import DPServices
import SwiftUI

/// Where a new connection is described.
///
/// Which fields appear comes from `ProtocolDescriptor`, not from a `switch` on the protocol. Adding
/// WebDAV in M3 should mean adding a row to `ProtocolCatalog` and changing nothing here.
struct ConnectionSheet: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var form = ConnectionFormModel()
    @State private var savesBookmark = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Protocol", selection: $form.protocolIdentifier) {
                    ForEach(form.catalog.descriptors) { descriptor in
                        Text(descriptor.displayName).tag(descriptor.id)
                    }
                }

                Section {
                    TextField("Server", text: $form.hostname, prompt: Text("example.com"))
                    TextField("Port", text: $form.port)

                    if form.shows(.username) {
                        TextField("User Name", text: $form.username)
                    }
                    if form.shows(.password) {
                        SecureField("Password", text: $form.password,
                                    prompt: Text("Leave blank to use the saved password"))
                        Toggle("Save password in Keychain", isOn: $form.savesPassword)
                    }
                    if form.shows(.defaultPath) {
                        TextField("Path", text: $form.defaultPath, prompt: Text("Optional"))
                    }
                }

                Section {
                    TextField("Nickname", text: $form.nickname, prompt: Text("Optional"))
                    Toggle("Add to bookmarks", isOn: $savesBookmark)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.isValid)
            }
            .padding(12)
        }
        .frame(width: 460)
    }

    private func connect() {
        guard let host = form.makeHost() else { return }
        let typed = form.makeCredentials()
        dismiss()

        Task {
            if savesBookmark {
                await environment.bookmarks?.save(host)
            }
            // A password typed here is handed to the coordinator so the engine finds it without a
            // second prompt; leaving the field blank falls through to the Keychain.
            if let typed {
                await environment.prompt.preload(typed, for: host)
            }
            await environment.browser?.connect(to: host)
        }
    }
}
