//
//  ConnectionFormModel.swift
//  DPPresentation
//

import DPCore
import DPCredentials
import DPServices
import Foundation
import Observation

/// The state behind the connection sheet, driven by what the protocol says it needs.
///
/// Which fields appear comes from ``ProtocolDescriptor/fields`` rather than from a `switch` in a view,
/// so adding WebDAV in M3 is a row in `ProtocolCatalog` and no view change at all.
@MainActor
@Observable
public final class ConnectionFormModel {

    /// Protocols the user can pick from.
    public let catalog: ProtocolCatalog

    /// Which protocol is selected. Changing it resets the port to that protocol's default.
    public var protocolIdentifier: ProtocolIdentifier {
        didSet {
            guard protocolIdentifier != oldValue else { return }
            port = String(catalog.defaultPort(for: protocolIdentifier) ?? 0)
        }
    }

    /// Server address.
    public var hostname = ""
    /// Port, as typed. Kept as text so a half-typed number is not silently reinterpreted.
    public var port: String
    /// Account name.
    public var username = ""
    /// Password, held only until the connection is made.
    public var password = ""
    /// Directory to open on connecting.
    public var defaultPath = ""
    /// Sidebar label.
    public var nickname = ""
    /// Free-text note about the connection, stored on the bookmark.
    public var details = ""

    // MARK: - Authentication

    /// How the user has chosen to log in. Saved on the bookmark, not in the Keychain — it is not a secret.
    public var authentication: AuthenticationKind = .password

    /// Path to the chosen private key, when ``authentication`` is `.privateKey`.
    ///
    /// Setting this directly does not validate it. Go through ``choosePrivateKey(at:locator:)``, or call
    /// ``discoverKeys(locator:agent:)`` afterwards, so ``privateKeyStatus`` keeps up.
    public var privateKeyPath = ""

    /// What is known about the file ``privateKeyPath`` names.
    ///
    /// The form checks the file as soon as it is chosen rather than leaving it to the connection. Picking
    /// `id_ed25519.pub` instead of `id_ed25519` is an easy mistake — the two sit side by side with nearly
    /// the same name — and discovering it as an authentication failure some seconds later, with no mention
    /// of the file, is a bad way to find out.
    public enum PrivateKeyStatus: Equatable, Sendable {

        /// No key chosen yet.
        case none

        /// A key that can be used.
        ///
        /// The algorithm may still be one this SSH transport cannot sign for — see
        /// ``DPCredentials/PrivateKeyLocator/DiscoveredKey/supportLevel``. That is a warning, not a
        /// rejection: an RSA key does work against an older server, so it is offered anyway (ADR 014).
        case usable(PrivateKeyLocator.DiscoveredKey)

        /// Not a usable key file, with a reason fit to show a person. Blocks submission.
        case rejected(reason: String)
    }

    /// Whether the chosen key file can be used. See ``PrivateKeyStatus``.
    public private(set) var privateKeyStatus: PrivateKeyStatus = .none

    /// The chosen key's file name, or `nil` when nothing is chosen. For the sheet's key row.
    public var privateKeyName: String? {
        let trimmed = privateKeyPath.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : (trimmed as NSString).lastPathComponent
    }

    /// Keys found in `~/.ssh`.
    ///
    /// No longer shown as a list — the sheet has one key row and a file panel that opens here. They are
    /// still worth finding, to offer a sensible default for a new connection.
    ///
    /// Empty until ``discoverKeys(locator:agent:)`` runs. Populated on demand rather than in `init`
    /// because it touches the file system, and a form model's initialiser runs many times as SwiftUI
    /// rebuilds the view.
    public private(set) var discoveredKeys: [PrivateKeyLocator.DiscoveredKey] = []

    /// Keys the running `ssh-agent` holds, or `nil` if there is no agent.
    ///
    /// `nil` and `[]` mean different things and the sheet says so differently: no agent at all versus an
    /// agent running with nothing loaded. The second is fixed by `ssh-add`; the first is not.
    public private(set) var agentIdentities: [SSHAgentIdentity]?

    /// The bookmark being edited, or `nil` when this form creates a new connection.
    ///
    /// Set by ``load(from:)``. Keeping the id is what makes a save an update: `BookmarkStore.save`
    /// upserts on it, so re-saving under a fresh `UUID` would silently duplicate the bookmark.
    public private(set) var editingID: UUID?

    /// The loaded bookmark's protocol-specific settings, carried through an edit untouched.
    ///
    /// The form has no field for most of these and never will — `"s3.region"` means nothing to a
    /// sheet that has not heard of S3. Rebuilding the bookmark without them would silently delete
    /// every setting this form does not understand, so they are kept and handed back.
    private var loadedProperties: [String: String] = [:]

    /// Whether this form is changing an existing bookmark rather than making one.
    public var isEditing: Bool { editingID != nil }

    /// Creates a form.
    ///
    /// - Parameters:
    ///   - catalog: Protocols to offer. Defaults to ``ProtocolCatalog/live``.
    ///   - protocolIdentifier: Which protocol starts selected. Defaults to the first in the catalog.
    public init(catalog: ProtocolCatalog = .live, protocolIdentifier: ProtocolIdentifier? = nil) {
        self.catalog = catalog
        let selected = protocolIdentifier ?? catalog.descriptors.first?.id ?? .sftp
        self.protocolIdentifier = selected
        self.port = String(catalog.defaultPort(for: selected) ?? 0)
    }

    /// The selected protocol's description, if it is supported.
    public var descriptor: ProtocolDescriptor? {
        catalog.descriptor(for: protocolIdentifier)
    }

    /// Whether a field should be shown for the selected protocol.
    /// - Parameter field: The field in question.
    public func shows(_ field: ProtocolField) -> Bool {
        descriptor?.fields.contains(field) ?? false
    }

    // MARK: - Authentication

    /// Ways of logging in the selected protocol accepts, in the order to offer them.
    ///
    /// From the descriptor rather than from a `switch` in a view, for the same reason as ``shows(_:)``:
    /// adding WebDAV should be a row in `ProtocolCatalog` and no view change at all.
    public var offeredAuthentications: [AuthenticationKind] {
        descriptor?.authentications ?? [.password]
    }

    /// Looks for keys in `~/.ssh`, asks whether an agent is running, and checks the chosen key.
    ///
    /// Call from a view's `.task`, not from `init`. Every answer here can change while the sheet is open —
    /// a user may run `ssh-add` in a terminal, or delete a key file, and come back — so this is safe to
    /// call again.
    ///
    /// Checking the key here rather than in ``load(from:)`` is what lets a bookmark whose key has since
    /// been moved or deleted say so *in the sheet*, instead of failing at connect time. `load(from:)`
    /// cannot do it: it runs inside the sheet's initialiser, which SwiftUI calls repeatedly, and this
    /// touches the file system.
    ///
    /// - Parameters:
    ///   - locator: Where to look for keys. Injectable so tests need no real `~/.ssh`.
    ///   - agent: The agent to ask, or `nil` to look for one in the environment.
    public func discoverKeys(
        locator: PrivateKeyLocator = PrivateKeyLocator(),
        agent: SSHAgentClient? = SSHAgentClient()
    ) {
        discoveredKeys = locator.discoverKeys()

        // A new connection starts on the strongest key already in ~/.ssh — `discoverKeys` returns them in
        // that order. It is only a default: it is never applied over a path the user or a bookmark chose.
        if privateKeyPath.isEmpty, let suggestion = discoveredKeys.first {
            privateKeyPath = suggestion.url.path
        }
        validatePrivateKey(using: locator)

        // A failure to reach the agent is reported as "no agent". The distinction between "not running"
        // and "running but unreachable" is not one the user can act on differently from this sheet.
        agentIdentities = agent.flatMap { try? $0.identities() }
    }

    /// Records a key the user picked from a file panel, and checks it.
    ///
    /// - Parameters:
    ///   - url: The key file.
    ///   - locator: Used to classify it, so the sheet can reject the wrong file and warn about an
    ///     algorithm that will not work.
    public func choosePrivateKey(at url: URL, locator: PrivateKeyLocator = PrivateKeyLocator()) {
        privateKeyPath = url.path
        authentication = .privateKey
        validatePrivateKey(using: locator)
    }

    /// Inspects the file ``privateKeyPath`` names and records the result in ``privateKeyStatus``.
    ///
    /// The reason for the file's rejection comes from `CredentialError` rather than being composed here:
    /// "that is a public key, you want the private half" is a fact about SSH keys, and belongs beside the
    /// code that recognises one.
    private func validatePrivateKey(using locator: PrivateKeyLocator) {
        let path = privateKeyPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else {
            privateKeyStatus = .none
            return
        }

        do {
            privateKeyStatus = .usable(try locator.inspectKey(at: URL(fileURLWithPath: path)))
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            privateKeyStatus = .rejected(reason: reason)
        }
    }

    /// Whether the form can be submitted.
    ///
    /// A hostname, a port that parses, and whatever the chosen login method needs:
    ///
    /// - **Password** — one, when creating, because a new connection has nothing in the Keychain to fall
    ///   back on. Editing accepts a blank password: it means "keep the saved one", not "no password".
    /// - **Public key** — a key path, always. Unlike a password there is nothing to fall back on, and a
    ///   bookmark saying "use a key" without naming one would silently become a password login.
    /// - **SSH agent** — nothing. The agent holds everything, and whether it will do is only knowable by
    ///   trying, so blocking the button on it would be a guess.
    public var isValid: Bool {
        guard !hostname.trimmingCharacters(in: .whitespaces).isEmpty, parsedPort != nil else {
            return false
        }

        switch authentication {
        case .password:
            return !(shows(.password) && password.isEmpty && !isEditing)
        case .privateKey:
            guard !privateKeyPath.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            // `.none` counts as valid: the file has not been looked at yet, and will be a moment later
            // when the sheet's `.task` runs. Only a file actually found wanting blocks the button.
            if case .rejected = privateKeyStatus { return false }
            return true
        case .agent:
            return true
        }
    }

    private var parsedPort: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)), (1...65_535).contains(value) else {
            return nil
        }
        return value
    }

    /// Builds the bookmark, or `nil` when the form is not valid.
    ///
    /// - Parameter id: Identity to use. Defaults to the loaded bookmark's, or a fresh one.
    public func makeHost(id: UUID? = nil) -> RemoteHost? {
        guard isValid, let parsedPort else { return nil }

        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespaces)
        let trimmedPath = defaultPath.trimmingCharacters(in: .whitespaces)
        let trimmedDetails = details.trimmingCharacters(in: .whitespaces)

        var host = RemoteHost(
            id: id ?? editingID ?? UUID(),
            protocolIdentifier: protocolIdentifier,
            hostname: hostname.trimmingCharacters(in: .whitespaces),
            port: parsedPort,
            username: trimmedUser.isEmpty ? nil : trimmedUser,
            defaultPath: trimmedPath.isEmpty ? nil : RemotePath(trimmedPath),
            nickname: trimmedNickname.isEmpty ? nil : trimmedNickname,
            comment: trimmedDetails.isEmpty ? nil : trimmedDetails,
            properties: loadedProperties
        )
        host.authenticationPreference = authenticationPreference
        return host
    }

    /// The login choice as the bookmark stores it.
    private var authenticationPreference: AuthenticationPreference {
        switch authentication {
        case .password: .password
        case .privateKey: .privateKey(path: privateKeyPath.trimmingCharacters(in: .whitespaces))
        case .agent: .agent
        }
    }

    /// Credentials from what was typed.
    ///
    /// Always saved to the Keychain on success — the sheet no longer offers a choice, because a
    /// connection worth creating is one worth reconnecting to without retyping.
    ///
    /// `nil` for a key or agent login, and not because nothing was typed: those credentials are built at
    /// connect time by `CredentialCoordinator`, which reads the key off disk and prompts for a passphrase
    /// if it needs one. A form has no business loading key material.
    public func makeCredentials() -> Credentials? {
        guard authentication == .password, !password.isEmpty else { return nil }
        return .password(
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            shouldPersist: true
        )
    }

    /// Fills the form from an existing bookmark, for editing.
    ///
    /// The password is deliberately not loaded — it lives in the Keychain and is never read back into a
    /// text field. Leaving it blank keeps it.
    ///
    /// - Parameter host: The bookmark to load.
    public func load(from host: RemoteHost) {
        editingID = host.id
        loadedProperties = host.properties
        protocolIdentifier = host.protocolIdentifier
        hostname = host.hostname
        port = String(host.port)
        username = host.username ?? ""
        defaultPath = host.defaultPath?.pathString ?? ""
        nickname = host.nickname ?? ""
        details = host.comment ?? ""
        password = ""

        let preference = host.authenticationPreference
        authentication = preference.kind
        privateKeyPath = preference.privateKeyPath ?? host.properties[RemoteHost.privateKeyPathKey] ?? ""
    }
}
