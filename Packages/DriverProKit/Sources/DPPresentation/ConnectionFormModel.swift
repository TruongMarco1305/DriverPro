//
//  ConnectionFormModel.swift
//  DPPresentation
//

import DPCore
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

    /// The bookmark being edited, or `nil` when this form creates a new connection.
    ///
    /// Set by ``load(from:)``. Keeping the id is what makes a save an update: `BookmarkStore.save`
    /// upserts on it, so re-saving under a fresh `UUID` would silently duplicate the bookmark.
    public private(set) var editingID: UUID?

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

    /// Whether the form can be submitted.
    ///
    /// A hostname, a port that parses, and — when creating — a password, because a new connection has
    /// nothing in the Keychain to fall back on. Editing an existing bookmark accepts a blank password:
    /// it means "keep the saved one" rather than "connect with no password".
    public var isValid: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && parsedPort != nil
            && !(shows(.password) && password.isEmpty && !isEditing)
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

        return RemoteHost(
            id: id ?? editingID ?? UUID(),
            protocolIdentifier: protocolIdentifier,
            hostname: hostname.trimmingCharacters(in: .whitespaces),
            port: parsedPort,
            username: trimmedUser.isEmpty ? nil : trimmedUser,
            defaultPath: trimmedPath.isEmpty ? nil : RemotePath(trimmedPath),
            nickname: trimmedNickname.isEmpty ? nil : trimmedNickname,
            comment: trimmedDetails.isEmpty ? nil : trimmedDetails
        )
    }

    /// Credentials from what was typed.
    ///
    /// Always saved to the Keychain on success — the sheet no longer offers a choice, because a
    /// connection worth creating is one worth reconnecting to without retyping.
    public func makeCredentials() -> Credentials? {
        guard !password.isEmpty else { return nil }
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
        protocolIdentifier = host.protocolIdentifier
        hostname = host.hostname
        port = String(host.port)
        username = host.username ?? ""
        defaultPath = host.defaultPath?.pathString ?? ""
        nickname = host.nickname ?? ""
        details = host.comment ?? ""
        password = ""
    }
}
