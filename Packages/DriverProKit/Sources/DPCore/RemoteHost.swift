//
//  RemoteHost.swift
//  DPCore
//

import Foundation

/// Identifies a protocol implementation, such as SFTP or S3.
///
/// A `String`-backed wrapper rather than an `enum` on purpose. An enum would mean every new protocol
/// forces a recompile of `DPCore` and makes every `switch` in the app non-exhaustive — the exact coupling
/// the layering rules exist to prevent. A wrapper keeps the type safety of a distinct type (you cannot
/// pass a hostname where a protocol id belongs) while staying open for extension.
///
/// ## Swift note — `RawRepresentable`
/// Conforming to `RawRepresentable` with a `String` raw value gets `Codable`, `Hashable`, and
/// `ExpressibleByStringLiteral`-style ergonomics almost for free, and the raw value is what gets written
/// into saved bookmarks.
public struct ProtocolIdentifier: RawRepresentable, Hashable, Sendable, Codable {
    /// The stable string token written into saved bookmarks, such as `"sftp"`.
    public let rawValue: String

    /// Creates a protocol identifier from its stable string form.
    /// - Parameter rawValue: A short lowercase token, stored verbatim in bookmarks.
    public init(rawValue: String) { self.rawValue = rawValue }

    /// SSH File Transfer Protocol.
    public static let sftp = ProtocolIdentifier(rawValue: "sftp")
    /// WebDAV over HTTPS, including Nextcloud and ownCloud.
    public static let webdav = ProtocolIdentifier(rawValue: "webdav")
    /// Amazon S3 and S3-compatible services.
    public static let s3 = ProtocolIdentifier(rawValue: "s3")
    /// File Transfer Protocol, with or without TLS.
    public static let ftp = ProtocolIdentifier(rawValue: "ftp")
}

/// A saved connection — everything needed to reach a server *except* the secret.
///
/// This is DriverPro's bookmark. It is deliberately `Codable` and deliberately contains no password,
/// passphrase, or access key. Secrets live in the Keychain and are looked up at connect time using this
/// value's ``keychainAccount`` and ``keychainService``. That separation is what makes it safe to write
/// a bookmark to disk, export it, or attach it to a bug report.
///
/// ## Swift note — `struct` and value semantics
/// A `struct`, not a `class`. Assigning one copies it, so a view holding a bookmark cannot be mutated out
/// from under it by a background task editing the "same" bookmark. Reference types are for things with
/// identity and shared mutable state; a bookmark is a value describing a place.
public struct RemoteHost: Hashable, Sendable, Codable, Identifiable {

    // MARK: - Identity

    /// Stable identity, preserved across edits so the sidebar selection survives a rename.
    public var id: UUID

    /// Which protocol implementation to use.
    public var protocolIdentifier: ProtocolIdentifier

    // MARK: - Location

    /// Host name or IP address. For S3 this is the endpoint, such as `s3.amazonaws.com`.
    public var hostname: String

    /// TCP port.
    public var port: Int

    /// Account name, or `nil` when the user has not chosen one yet.
    ///
    /// Optional rather than `""` so "no username recorded" is distinguishable from "the username is
    /// deliberately empty", which matters for anonymous FTP.
    public var username: String?

    /// Directory to open on connecting. `nil` means the server's default — the SFTP home directory, the
    /// WebDAV root, the bucket list.
    public var defaultPath: RemotePath?

    // MARK: - Presentation

    /// User-chosen label for the sidebar. When `nil`, ``displayName`` falls back to the address.
    public var nickname: String?

    /// Free-text notes attached to the bookmark.
    public var comment: String?

    // MARK: - Protocol-specific settings

    /// Settings meaningful only to one protocol.
    ///
    /// Examples: `"s3.region"`, `"ftp.passive"`, `"sftp.privateKeyPath"`. Kept out of the stored
    /// properties for the same reason as ``RemoteItem/extra`` — otherwise this type accumulates a field
    /// per protocol and is mostly `nil` for every one of them.
    ///
    /// A file *path* to a private key belongs here; the key's passphrase does not. Paths are not secrets.
    public var properties: [String: String]

    // MARK: - Initialisation

    /// Creates a bookmark.
    ///
    /// - Parameters:
    ///   - id: Stable identity. Defaults to a fresh `UUID`.
    ///   - protocolIdentifier: Which protocol to speak.
    ///   - hostname: Server address.
    ///   - port: TCP port. Pass the protocol's default if unsure.
    ///   - username: Account name, if known.
    ///   - defaultPath: Directory to open on connect.
    ///   - nickname: Sidebar label.
    ///   - comment: Free-text notes.
    ///   - properties: Protocol-specific settings.
    public init(
        id: UUID = UUID(),
        protocolIdentifier: ProtocolIdentifier,
        hostname: String,
        port: Int,
        username: String? = nil,
        defaultPath: RemotePath? = nil,
        nickname: String? = nil,
        comment: String? = nil,
        properties: [String: String] = [:]
    ) {
        self.id = id
        self.protocolIdentifier = protocolIdentifier
        self.hostname = hostname
        self.port = port
        self.username = username
        self.defaultPath = defaultPath
        self.nickname = nickname
        self.comment = comment
        self.properties = properties
    }

    // MARK: - Derived values

    /// The fields that decide *where and how* a connection is made, without the ones that do not.
    ///
    /// Two bookmarks with the same ``id`` are the same row in the sidebar; two with the same
    /// `connectionIdentity` are the same conversation with a server. Those are different questions, and
    /// conflating them is how an edited bookmark ends up still talking to the old address — a pooled
    /// connection is keyed by identity, and an identity alone does not change when the port does.
    ///
    /// Deliberately excludes ``nickname``, ``comment`` and ``defaultPath``: renaming a bookmark or
    /// changing which folder it opens at is no reason to drop a working connection.
    /// ``authenticationPreference`` needs no entry of its own — it is derived from ``properties``.
    public var connectionIdentity: ConnectionIdentity {
        ConnectionIdentity(
            protocolIdentifier: protocolIdentifier,
            hostname: hostname,
            port: port,
            username: username,
            properties: properties
        )
    }

    /// Where and how to connect, as a value that can be compared.
    ///
    /// See ``RemoteHost/connectionIdentity``.
    public struct ConnectionIdentity: Hashable, Sendable {
        /// Which protocol is spoken.
        public let protocolIdentifier: ProtocolIdentifier
        /// The server's address.
        public let hostname: String
        /// The port dialled.
        public let port: Int
        /// Who to log in as, if anyone.
        public let username: String?
        /// The settings that shape a connection rather than describe it — a WebDAV DAV root, an
        /// authentication choice, a private key path.
        public let properties: [String: String]
    }

    /// What to call this connection: the nickname, else the user name, else the address.
    ///
    /// The address is the last resort rather than part of the fallback, so a sidebar full of bookmarks
    /// is not also a list of the servers someone can reach.
    public var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        if let username, !username.isEmpty { return username }
        return hostname
    }

    /// A second line beneath ``displayName``, or `nil` when there is nothing left to add.
    ///
    /// Only the user name, and only when the title is a nickname — otherwise the row would say the same
    /// thing twice.
    public var subtitle: String? {
        guard let nickname, !nickname.isEmpty,
              let username, !username.isEmpty else { return nil }
        return username
    }

    // MARK: - Keychain addressing

    /// The Keychain service string for this connection's secret.
    ///
    /// Matches the `protocol://host:port` shape Cyberduck uses, so a machine running both apps does not
    /// end up with two unrelated copies of the same password.
    public var keychainService: String {
        "\(protocolIdentifier.rawValue)://\(hostname):\(port)"
    }

    /// The Keychain account string — the user name, or `""` for anonymous connections.
    public var keychainAccount: String { username ?? "" }
}
