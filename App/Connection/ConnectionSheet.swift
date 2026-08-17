//
//  ConnectionSheet.swift
//  DriverPro
//

import DPCore
import DPPresentation
import DPServices
import SwiftUI

/// Where a connection is made or changed: pick a protocol, then describe the server.
///
/// Both steps are driven by `ProtocolDescriptor` rather than by a `switch` on the protocol — the chooser
/// reads the catalog, and which fields appear comes from the chosen descriptor. Adding WebDAV in M3
/// should mean adding a row to `ProtocolCatalog` and changing nothing here.
///
/// Editing skips the chooser and keeps the bookmark's identity, so a save updates the row rather than
/// adding a second one.
/// ## Swift note — seeding `@State` in an initialiser
/// Loading the bookmark in `.task` drew one frame with nothing chosen, so editing flashed the chooser
/// before the form. `State(initialValue:)` sets the value before the first frame instead. SwiftUI builds
/// a `View` struct many times for one appearance and keeps only the first initial value, so this is safe
/// even though `init` runs repeatedly. See `docs/swift-notes.md`, section 29.
@MainActor
struct ConnectionSheet: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let mode: ConnectionSheetMode

    @State private var form: ConnectionFormModel

    /// `nil` while the chooser is up. Setting it is what advances to the form.
    @State private var chosen: ProtocolIdentifier?

    /// Creates the sheet, already filled in when editing.
    /// - Parameter mode: Whether this describes a new connection or changes a saved one.
    init(mode: ConnectionSheetMode) {
        self.mode = mode

        let form = ConnectionFormModel()
        var chosen: ProtocolIdentifier?
        if case .edit(let host) = mode {
            form.load(from: host)
            chosen = host.protocolIdentifier      // editing skips the chooser entirely
        }
        _form = State(initialValue: form)
        _chosen = State(initialValue: chosen)
    }

    var body: some View {
        Group {
            if chosen == nil {
                ProtocolChooser(catalog: form.catalog) { identifier in
                    // Assigning this resets the port to the protocol's default, so the form never opens
                    // holding a port typed for a different protocol.
                    form.protocolIdentifier = identifier
                    chosen = identifier
                } cancel: {
                    dismiss()
                }
            } else {
                details
            }
        }
        .frame(width: 460)
    }

    // MARK: - Step two

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Server", text: $form.hostname, prompt: Text("example.com"))
                    TextField("Port", text: $form.port)

                    if form.shows(.username) {
                        TextField("User Name", text: $form.username)
                    }
                    if form.shows(.password) {
                        SecureField("Password", text: $form.password,
                                    prompt: form.isEditing ? Text("Leave blank to keep the saved one")
                                                           : nil)
                    }
                    if form.shows(.defaultPath) {
                        TextField("Path", text: $form.defaultPath, prompt: Text("Optional"))
                    }
                } header: {
                    chosenProtocolHeader
                }

                Section {
                    TextField("Nickname", text: $form.nickname, prompt: Text("Optional"))
                    TextField("Description", text: $form.details, prompt: Text("Optional"),
                              axis: .vertical)
                        .lineLimit(1...3)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if !form.isEditing {
                    Button("Back") { chosen = nil }
                        .help("Choose a different connection type")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(form.isEditing ? "Save" : "Connect") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.isValid)
            }
            .padding(12)
        }
    }

    /// Names the protocol chosen in step one, since the picker that used to say so is gone.
    @ViewBuilder
    private var chosenProtocolHeader: some View {
        if let descriptor = form.descriptor {
            HStack(spacing: 6) {
                Image(systemName: descriptor.iconName)
                Text(descriptor.displayName)
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
        }
    }

    /// Saves the bookmark, and connects when this is a new connection.
    ///
    /// A typed password is handed to the prompt rather than written to the Keychain here: only a
    /// password the *server* accepted is worth keeping, so it is stored after a successful connect. See
    /// `CredentialCoordinator`.
    ///
    /// Editing the host, port or user name changes the Keychain key those fields derive, so the old
    /// secret stays behind under the old one and the next connect asks once.
    private func submit() {
        guard let host = form.makeHost() else { return }
        let typed = form.makeCredentials()
        let isEditing = form.isEditing
        dismiss()

        // Bookmarking and saving the password are no longer choices: a connection worth making is one
        // worth returning to, and the sidebar is the only way back to it.
        Task {
            await environment.bookmarks?.save(host)
            if let typed {
                await environment.prompt.preload(typed, for: host)
            }
            guard !isEditing else { return }      // editing must not disturb the open connection
            await environment.browser?.connect(to: host)
        }
    }
}
