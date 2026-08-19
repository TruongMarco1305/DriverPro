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

    /// Whether the key file panel is up.
    @State private var isChoosingKey = false

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
        // Not in `init`: this touches the file system and asks the agent, and a `View` initialiser runs
        // many times as SwiftUI rebuilds. Both answers can also change while the sheet is open.
        .task { form.discoverKeys() }
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
                    authentication
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

    // MARK: - Authentication

    /// The login method, and whatever that choice needs.
    ///
    /// Which methods appear comes from `ProtocolDescriptor.authentications`, so this is not a `switch` on
    /// the protocol — but it is a `switch` on the *method*, because each one genuinely needs a different
    /// control. The picker itself is hidden when a protocol offers only one way in, since a picker with a
    /// single choice is just a label.
    @ViewBuilder
    private var authentication: some View {
        if form.offeredAuthentications.count > 1 {
            Picker("Authenticate", selection: $form.authentication) {
                ForEach(form.offeredAuthentications, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
        }

        switch form.authentication {
        case .password:
            if form.shows(.password) {
                SecureField("Password", text: $form.password,
                            prompt: form.isEditing ? Text("Leave blank to keep the saved one") : nil)
            }
        case .privateKey:
            keyPicker
        case .agent:
            agentStatus
        }
    }

    /// One row: which key is chosen, and a button to change it.
    ///
    /// The note underneath is the point of the whole control. An `id_rsa` cannot work with this SSH
    /// transport, and an `id_ed25519.pub` is the wrong half of the pair — finding either out from a failed
    /// login, which says nothing about the file, is a bad afternoon. See ADR 014.
    @ViewBuilder
    private var keyPicker: some View {
        LabeledContent("Private Key") {
            HStack {
                Text(form.privateKeyName ?? "None selected")
                    .foregroundStyle(form.privateKeyName == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") { isChoosingKey = true }
            }
        }
        .fileImporter(isPresented: $isChoosingKey, allowedContentTypes: [.data]) { result in
            // No security-scoped bookmark: the app is deliberately not sandboxed, so the raw path is
            // enough and goes straight onto the bookmark. See ADR 004.
            if case .success(let url) = result { form.choosePrivateKey(at: url) }
        }
        // `~/.ssh` is a dot directory, so without `.includeHiddenFiles` the panel opens into a folder that
        // appears empty. Opening there at all is what replaces the list of discovered keys this row used
        // to show: the common choice is one click away rather than a hunt.
        .fileDialogDefaultDirectory(URL.homeDirectory.appending(path: ".ssh"))
        .fileDialogBrowserOptions(.includeHiddenFiles)

        keyStatus
    }

    /// What is wrong with the chosen key, or what to expect from it.
    @ViewBuilder
    private var keyStatus: some View {
        switch form.privateKeyStatus {
        case .none:
            EmptyView()

        case .rejected(let reason):
            // Connect is disabled while this shows — see `ConnectionFormModel.isValid`.
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)

        case .usable(let key):
            switch key.supportLevel {
            case .supported:
                if key.isEncrypted {
                    Label("This key has a passphrase. DriverPro will ask for it once, and can remember it.",
                          systemImage: "lock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .unsupported(let reason):
                // Orange, not red, and Connect stays enabled: the key is real and may satisfy an older
                // server. ADR 014 chose to attempt rather than refuse.
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            case .caveat(let note):
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Whether an agent is running and what it holds.
    ///
    /// "No agent" and "an agent holding nothing" are shown differently because only the second is fixed by
    /// `ssh-add`. Neither disables the Connect button: whether a given key will satisfy this server is only
    /// knowable by trying, and refusing to try would be a guess.
    @ViewBuilder
    private var agentStatus: some View {
        switch form.agentIdentities {
        case .none:
            Label("No ssh-agent is running. Start one and add a key with `ssh-add`.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        case .some(let identities) where identities.isEmpty:
            Label("The ssh-agent is running but holds no keys. Add one with `ssh-add`.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        case .some(let identities):
            VStack(alignment: .leading, spacing: 2) {
                Text("^[\(identities.count) key](inflect: true) available:")
                    .foregroundStyle(.secondary)
                ForEach(identities, id: \.keyBlob) { identity in
                    Text(identity.displayName).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
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
