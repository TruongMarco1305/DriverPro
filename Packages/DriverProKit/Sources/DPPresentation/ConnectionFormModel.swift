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
    /// Whether to save the password once the server accepts it.
    public var savesPassword = true

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
    /// A hostname and a port that parses. Everything else is optional — anonymous FTP has no user name,
    /// and a password may come from the Keychain.
    public var isValid: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty && parsedPort != nil
    }

    private var parsedPort: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)), (1...65_535).contains(value) else {
            return nil
        }
        return value
    }

    /// Builds the bookmark, or `nil` when the form is not valid.
    ///
    /// - Parameter id: Identity to use. Pass an existing bookmark's id to edit it in place.
    public func makeHost(id: UUID = UUID()) -> RemoteHost? {
        guard isValid, let parsedPort else { return nil }

        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespaces)
        let trimmedPath = defaultPath.trimmingCharacters(in: .whitespaces)

        return RemoteHost(
            id: id,
            protocolIdentifier: protocolIdentifier,
            hostname: hostname.trimmingCharacters(in: .whitespaces),
            port: parsedPort,
            username: trimmedUser.isEmpty ? nil : trimmedUser,
            defaultPath: trimmedPath.isEmpty ? nil : RemotePath(trimmedPath),
            nickname: trimmedNickname.isEmpty ? nil : trimmedNickname
        )
    }

    /// Credentials from what was typed, or `nil` if no password was given.
    ///
    /// A blank password is not the same as no password: leaving it empty means "use what is saved", so
    /// this returns `nil` and the coordinator falls back to the credential store.
    public func makeCredentials() -> Credentials? {
        guard !password.isEmpty else { return nil }
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        return .password(
            username: trimmedUser,
            password: password,
            shouldPersist: savesPassword
        )
    }

    /// Fills the form from an existing bookmark, for editing.
    /// - Parameter host: The bookmark to load.
    public func load(from host: RemoteHost) {
        protocolIdentifier = host.protocolIdentifier
        hostname = host.hostname
        port = String(host.port)
        username = host.username ?? ""
        defaultPath = host.defaultPath?.pathString ?? ""
        nickname = host.nickname ?? ""
        password = ""
    }
}
