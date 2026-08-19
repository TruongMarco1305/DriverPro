//
//  Authentication.swift
//  DPCore
//

import Foundation

// MARK: - Kind

/// A way of proving identity, as advertised by a protocol and offered in a picker.
///
/// Note what this is *not*: it is not ``Credentials/Method``. That type carries the secret and lives
/// only in memory. This one names a choice, contains nothing secret, and is saved on the bookmark.
/// Keeping them apart is what lets a bookmark say "log in with a key" without a key being anywhere
/// near it.
public enum AuthenticationKind: String, Hashable, Sendable, CaseIterable {

    /// A password, typed or read from the Keychain.
    case password

    /// A private key file on disk, unlocked by a passphrase if it is encrypted.
    case privateKey

    /// The running `ssh-agent`, which signs on our behalf and never releases the key itself.
    case agent

    /// What to call this in a picker.
    ///
    /// On the model rather than in the view for the same reason as ``RemoteHost/displayName``: there
    /// is one right answer and it should not be restated per call site.
    public var displayName: String {
        switch self {
        case .password: "Password"
        case .privateKey: "Public Key"
        case .agent: "SSH Agent"
        }
    }
}

// MARK: - Preference

/// How one bookmark has chosen to authenticate.
///
/// Distinct from ``AuthenticationKind`` because a choice of public key is meaningless without saying
/// *which* key: this enum carries the path, so "public key, but no key" cannot be expressed. The
/// kind is what a picker iterates; the preference is what a bookmark stores.
///
/// There is deliberately no `automatic` case. DriverPro asks which method to use rather than trying
/// several silently, so that a refused login can say what was offered.
public enum AuthenticationPreference: Hashable, Sendable {

    /// Use a password, from the Keychain if one is saved.
    case password

    /// Use the private key at this path.
    /// - Parameter path: A file system path. Not a secret — see ``RemoteHost/properties``.
    case privateKey(path: String)

    /// Use the running `ssh-agent`.
    case agent

    /// Which kind of authentication this is, dropping any detail.
    public var kind: AuthenticationKind {
        switch self {
        case .password: .password
        case .privateKey: .privateKey
        case .agent: .agent
        }
    }

    /// The private key path, when one applies.
    public var privateKeyPath: String? {
        guard case .privateKey(let path) = self else { return nil }
        return path
    }
}
