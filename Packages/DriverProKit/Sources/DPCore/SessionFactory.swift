//
//  SessionFactory.swift
//  DPCore
//

import Foundation

/// Creates a `Session` for a bookmark, without the caller knowing which protocol is involved.
///
/// This is the seam that keeps `DPTransfer` protocol-agnostic. The connection pool must open sessions,
/// but it cannot import `DPProtocolSFTP` without breaking the layering rule — so the app's composition
/// root supplies a factory instead, and it is the only place that knows SFTP exists.
public protocol SessionFactory: Sendable {

    /// Creates a session for a bookmark. The session is not yet connected.
    ///
    /// - Parameter host: The bookmark to build a session for.
    /// - Returns: An unconnected session.
    /// - Throws: ``SessionError/unknownProtocol(_:)`` if no backend is registered for the protocol.
    func makeSession(for host: RemoteHost) throws -> any Session
}

/// A factory built from closures, one per protocol.
///
/// Saves the app from declaring a type whose only job is a `switch`:
///
/// ```swift
/// let factory = ClosureSessionFactory([.sftp: { SFTPSession(host: $0) }])
/// ```
public struct ClosureSessionFactory: SessionFactory {

    private let builders: [ProtocolIdentifier: @Sendable (RemoteHost) throws -> any Session]

    /// Creates a factory from a table of builders.
    ///
    /// The closures may throw: not every bookmark can be turned into a session even when its protocol is
    /// supported — a WebDAV bookmark whose host name does not make a URL, for instance. A non-throwing
    /// closure still fits, so existing tables are unaffected.
    ///
    /// - Parameter builders: One closure per supported protocol.
    public init(_ builders: [ProtocolIdentifier: @Sendable (RemoteHost) throws -> any Session]) {
        self.builders = builders
    }

    /// Builds a session using the closure registered for the bookmark's protocol.
    /// - Parameter host: The bookmark to build for.
    /// - Returns: An unconnected session.
    /// - Throws: ``SessionError/unknownProtocol(_:)`` when no closure is registered, or whatever the
    ///   closure throws when the bookmark cannot produce a session.
    public func makeSession(for host: RemoteHost) throws -> any Session {
        guard let build = builders[host.protocolIdentifier] else {
            throw SessionError.unknownProtocol(host.protocolIdentifier)
        }
        return try build(host)
    }
}
