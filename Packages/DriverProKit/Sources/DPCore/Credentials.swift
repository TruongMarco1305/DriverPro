//
//  Credentials.swift
//  DPCore
//

import Foundation

/// The secret half of a connection, held in memory only.
///
/// Note what this type deliberately is **not**: it is not `Codable`, and it never will be. Making it
/// `Codable` is one autocomplete away from a password landing in a plist, a log line, or a crash report.
/// Persisting a secret goes through `DPCredentials` and the Keychain — there is no other supported path.
/// The compiler enforces this: you cannot `JSONEncoder().encode(credentials)` because the conformance
/// does not exist.
///
/// For the same reason ``description`` is redacted rather than synthesised, so an accidental
/// `print(credentials)` or string interpolation cannot leak the value.
public struct Credentials: Sendable {

    // MARK: - Method

    /// How the client proves who it is.
    ///
    /// ## Swift note — enums with associated values, again
    /// Each case carries exactly the data that method needs and nothing more. There is no way to
    /// construct a `.password` that also has a private key, or a `.privateKey` with no key data — states
    /// that a struct with four optional fields would happily allow. This is *making illegal states
    /// unrepresentable*, and it is one of the most useful things Swift's type system offers.
    public enum Method: Sendable {
        /// No credentials; anonymous access.
        case anonymous

        /// A plain password or, for S3, a secret access key.
        case password(String)

        /// An SSH private key, optionally protected by a passphrase.
        ///
        /// - Parameters:
        ///   - data: The key file's raw bytes, in PEM or OpenSSH format.
        ///   - passphrase: The passphrase, if the key is encrypted.
        case privateKey(data: Data, passphrase: String?)

        /// An OAuth or session bearer token.
        case token(String)
    }

    // MARK: - Stored properties

    /// The account name to authenticate as.
    public var username: String

    /// How to prove ownership of that account.
    public var method: Method

    /// Whether the user asked for this secret to be saved to the Keychain.
    ///
    /// The session itself never acts on this; it is a request that the caller honours after a successful
    /// connection. Saving before the server has accepted the credentials would persist a wrong password.
    public var shouldPersist: Bool

    // MARK: - Initialisation

    /// Creates a credential.
    ///
    /// - Parameters:
    ///   - username: The account name.
    ///   - method: How to authenticate.
    ///   - shouldPersist: Whether to save to the Keychain once the server accepts these credentials.
    public init(username: String, method: Method, shouldPersist: Bool = false) {
        self.username = username
        self.method = method
        self.shouldPersist = shouldPersist
    }

    /// Creates a password credential.
    ///
    /// - Parameters:
    ///   - username: The account name.
    ///   - password: The password.
    ///   - shouldPersist: Whether to save to the Keychain on success.
    public static func password(
        username: String,
        password: String,
        shouldPersist: Bool = false
    ) -> Credentials {
        Credentials(username: username, method: .password(password), shouldPersist: shouldPersist)
    }

    /// Anonymous credentials, as used by public FTP servers.
    /// - Parameter username: The account name to present. Defaults to `"anonymous"`.
    public static func anonymous(username: String = "anonymous") -> Credentials {
        Credentials(username: username, method: .anonymous)
    }

}

// MARK: - Redacted description

extension Credentials: CustomStringConvertible, CustomDebugStringConvertible {
    /// A description naming the method but never the secret.
    ///
    /// Both `description` and `debugDescription` are overridden. The debug one matters most: it is what
    /// the Xcode console and `dump()` reach for, which is exactly where a leaked password would be least
    /// noticed and most durable.
    public var description: String {
        let methodName: String = switch method {
        case .anonymous: "anonymous"
        case .password: "password ⟨redacted⟩"
        case .privateKey(_, let passphrase): "privateKey ⟨redacted⟩\(passphrase == nil ? "" : " +passphrase")"
        case .token: "token ⟨redacted⟩"
        }
        return "Credentials(username: \(username), method: \(methodName))"
    }

    /// Identical to ``description``: the debugger and `dump()` must not see a secret either.
    public var debugDescription: String { description }
}
