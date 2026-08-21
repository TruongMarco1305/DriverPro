//
//  RemoteHostAuthentication.swift
//  DPCore
//

import Foundation

extension RemoteHost {

    // MARK: - Property keys

    /// The ``properties`` key naming the chosen authentication method.
    public static let authenticationMethodKey = "sftp.authMethod"

    /// The ``properties`` key holding the path to a private key.
    ///
    /// The name ``properties`` documents, and the one Cyberduck writes, so a bookmark imported from
    /// it lands on the right field.
    public static let privateKeyPathKey = "sftp.privateKeyPath"

    /// The ``properties`` key holding a WebDAV server's DAV root.
    ///
    /// `/remote.php/dav/files/duck` for Nextcloud, empty for a server that publishes at `/`. It lives
    /// here rather than in the WebDAV target because the *connection form* writes it, and
    /// `DPPresentation` may not import a protocol target — the same reason ``privateKeyPathKey`` is
    /// here rather than in the SFTP one.
    ///
    /// That this is a property rather than a field on `RemoteHost` is the claim M3 set out to test: a
    /// vendor's layout should be configuration, not a branch.
    public static let webdavBasePathKey = "webdav.basePath"

    // MARK: - Preference

    /// How this bookmark authenticates, stored in ``properties``.
    ///
    /// Both halves live in ``properties`` rather than as stored fields on `RemoteHost`, for the reason
    /// that property bag exists: otherwise this type grows a field per protocol. Being a JSON column
    /// in SQLite, it also means no schema migration.
    ///
    /// The getter is forgiving on purpose. A bookmark written by a newer DriverPro, hand-edited, or
    /// imported from elsewhere can hold an unrecognised method or name a key that is no longer there;
    /// degrading to ``AuthenticationPreference/password`` asks the user for a password, which is
    /// recoverable. Trapping, or refusing to load the bookmark, is not.
    ///
    /// Setting a method other than `privateKey` leaves any recorded key path in place, so switching to
    /// a password and back does not lose it. That is why the getter has to check for an empty path
    /// rather than trusting the method alone.
    public var authenticationPreference: AuthenticationPreference {
        get {
            switch properties[Self.authenticationMethodKey] {
            case AuthenticationKind.privateKey.rawValue:
                guard let path = properties[Self.privateKeyPathKey], !path.isEmpty else {
                    return .password
                }
                return .privateKey(path: path)
            case AuthenticationKind.agent.rawValue:
                return .agent
            default:
                return .password
            }
        }
        set {
            properties[Self.authenticationMethodKey] = newValue.kind.rawValue
            if let path = newValue.privateKeyPath {
                properties[Self.privateKeyPathKey] = path
            }
        }
    }
}
