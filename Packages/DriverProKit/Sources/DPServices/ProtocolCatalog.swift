//
//  ProtocolCatalog.swift
//  DriverProKit
//
//  Target responsibility
//  ────────────────────
//  DPServices is the composition root: the one place that knows which protocols exist and how the
//  engine's parts fit together. It may import every other DP target; nothing may import it except the
//  app.
//
//  It holds wiring and protocol metadata only. Logic that belongs to a lower layer goes there instead.
//

import DPCore
import DPCredentials
import DPProtocolSFTP
import Foundation

/// A field the connection form may need to show.
public enum ProtocolField: String, Hashable, Sendable, CaseIterable {
    /// An account name.
    case username
    /// A password or secret access key.
    case password
    /// A path to an SSH private key.
    case privateKey
    /// A directory to open on connecting.
    case defaultPath
    /// An option to connect without credentials.
    case anonymous
}

/// What a protocol looks like to the user interface.
///
/// This is what stops the connection sheet from becoming a `switch` that grows a case per protocol.
/// The form is built from a descriptor, so adding WebDAV in M3 means adding a row here rather than
/// editing a view.
public struct ProtocolDescriptor: Hashable, Sendable, Identifiable {

    /// Which protocol this describes.
    public let id: ProtocolIdentifier
    /// Name to show in a picker, such as `"SFTP (SSH File Transfer)"`.
    public let displayName: String
    /// URL scheme, used in window titles and Keychain items.
    public let scheme: String
    /// Port used when the user does not give one.
    public let defaultPort: Int
    /// Fields the connection form should offer.
    public let fields: Set<ProtocolField>

    /// Creates a descriptor.
    ///
    /// - Parameters:
    ///   - id: The protocol.
    ///   - displayName: Name for a picker.
    ///   - scheme: URL scheme.
    ///   - defaultPort: Default TCP port.
    ///   - fields: Fields the form should offer.
    public init(
        id: ProtocolIdentifier,
        displayName: String,
        scheme: String,
        defaultPort: Int,
        fields: Set<ProtocolField>
    ) {
        self.id = id
        self.displayName = displayName
        self.scheme = scheme
        self.defaultPort = defaultPort
        self.fields = fields
    }
}

/// Every protocol DriverPro can speak, and how to build a session for one.
///
/// The only type that imports a `DPProtocol*` target. That containment is the layering rule paying off:
/// swapping the SFTP backend, or adding S3, touches this file and nothing above it.
public struct ProtocolCatalog: Sendable {

    /// The descriptors, in the order a picker should show them.
    public let descriptors: [ProtocolDescriptor]

    /// Creates a catalog.
    /// - Parameter descriptors: Supported protocols, in display order.
    public init(descriptors: [ProtocolDescriptor]) {
        self.descriptors = descriptors
    }

    /// What DriverPro currently supports.
    ///
    /// One entry today. WebDAV (M3), S3 (M4) and FTP (M5) join it here.
    public static let live = ProtocolCatalog(descriptors: [
        ProtocolDescriptor(
            id: .sftp,
            displayName: "SFTP (SSH File Transfer)",
            scheme: "sftp",
            defaultPort: 22,
            fields: [.username, .password, .privateKey, .defaultPath]
        )
    ])

    /// The descriptor for a protocol, or `nil` if it is not supported.
    /// - Parameter identifier: Which protocol.
    public func descriptor(for identifier: ProtocolIdentifier) -> ProtocolDescriptor? {
        descriptors.first { $0.id == identifier }
    }

    /// The default port for a protocol, or `nil` if it is not supported.
    /// - Parameter identifier: Which protocol.
    public func defaultPort(for identifier: ProtocolIdentifier) -> Int? {
        descriptor(for: identifier)?.defaultPort
    }

    /// Builds the factory that turns a bookmark into a session.
    ///
    /// - Parameter knownHosts: Where SSH host keys are read and recorded.
    /// - Returns: A factory covering every protocol in the catalog.
    public func makeSessionFactory(knownHosts: KnownHostsStore) -> any SessionFactory {
        ClosureSessionFactory([
            .sftp: { host in SFTPSession(host: host, knownHosts: knownHosts) }
        ])
    }
}
