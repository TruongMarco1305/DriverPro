//
//  KeychainStore.swift
//  DPCredentials
//

import DPCore
import Foundation
import Security

/// Stores and retrieves secrets in the macOS Keychain.
///
/// Passwords for servers are saved as **internet passwords** — the same class `Safari`, `ssh`, and
/// Cyberduck use — keyed by protocol, server, port, and account. That is what makes an item show up
/// sensibly in Keychain Access and what lets a machine running both DriverPro and Cyberduck share one
/// entry instead of accumulating two.
///
/// Passphrases for private key files are **generic passwords** instead, since a key on disk has no
/// server or port to key on.
///
/// ## Swift note — calling a C API from Swift
/// Security.framework is a C API, and it shows. Queries are `CFDictionary`s built from
/// `[String: Any]`, keys are global `CFString` constants that must be bridged with `as String`, and
/// every call returns an `OSStatus` integer rather than throwing. The wrapper exists so that ugliness
/// lives in one file and the rest of the app sees `try await keychain.password(for: host)`.
///
/// `SecItemCopyMatching` writes its result through an `UnsafeMutablePointer`, which is why the
/// `CFTypeRef?` is declared first and passed with `&`. Swift keeps it alive across the call.
public actor KeychainStore {

    /// Where to look. Injected so tests can be pointed at a throwaway keychain rather than the user's.
    private let serviceLabelPrefix: String

    /// Creates a keychain store.
    ///
    /// - Parameter serviceLabelPrefix: Prefix for generic-password service names, so test runs can be
    ///   isolated from real data. Defaults to `"DriverPro"`.
    public init(serviceLabelPrefix: String = "DriverPro") {
        self.serviceLabelPrefix = serviceLabelPrefix
    }

    // MARK: - Server passwords

    /// Reads the stored password for a connection.
    ///
    /// - Parameter host: The bookmark whose password is wanted.
    /// - Returns: The password, or `nil` if none is stored.
    /// - Throws: ``CredentialError/keychain(status:operation:)`` if the keychain refused for any reason
    ///   other than the item being absent — including the user dismissing the unlock prompt.
    public func password(for host: RemoteHost) throws -> String? {
        var query = internetQuery(for: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            // Not an error: the common case on a first connection.
            return nil
        default:
            throw CredentialError.keychain(status: status, operation: "read a password")
        }
    }

    /// Saves or replaces the password for a connection.
    ///
    /// Call this only *after* the server has accepted the credentials — saving first persists a wrong
    /// password and produces a bookmark that silently fails forever.
    ///
    /// - Parameters:
    ///   - password: The secret to store.
    ///   - host: The bookmark it belongs to.
    /// - Throws: ``CredentialError/keychain(status:operation:)`` if the item could not be written.
    public func setPassword(_ password: String, for host: RemoteHost) throws {
        let query = internetQuery(for: host)
        let secret = Data(password.utf8)

        // Try updating first. SecItemAdd on an existing item fails with errSecDuplicateItem rather than
        // replacing, so "add, and on duplicate update" is the usual dance — done in this order because
        // updating an existing password is the more common case once a bookmark is established.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: secret] as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = secret
            insert[kSecAttrLabel as String] = host.keychainService
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialError.keychain(status: addStatus, operation: "save a password")
            }
        default:
            throw CredentialError.keychain(status: updateStatus, operation: "update a password")
        }
    }

    /// Deletes the stored password for a connection.
    ///
    /// Deleting something that is not there succeeds — the caller wanted it gone, and it is.
    ///
    /// - Parameter host: The bookmark whose password should be removed.
    /// - Throws: ``CredentialError/keychain(status:operation:)`` if the keychain refused.
    public func removePassword(for host: RemoteHost) throws {
        let status = SecItemDelete(internetQuery(for: host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychain(status: status, operation: "delete a password")
        }
    }

    // MARK: - Private key passphrases

    /// Reads the stored passphrase for a private key file.
    ///
    /// - Parameter path: Filesystem path of the key, used as the item's account.
    /// - Returns: The passphrase, or `nil` if none is stored.
    /// - Throws: ``CredentialError/keychain(status:operation:)`` on keychain failure.
    public func passphrase(forPrivateKeyAt path: String) throws -> String? {
        var query = genericQuery(account: path)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialError.keychain(status: status, operation: "read a passphrase")
        }
    }

    /// Saves or replaces the passphrase for a private key file.
    ///
    /// - Parameters:
    ///   - passphrase: The secret to store.
    ///   - path: Filesystem path of the key.
    /// - Throws: ``CredentialError/keychain(status:operation:)`` if the item could not be written.
    public func setPassphrase(_ passphrase: String, forPrivateKeyAt path: String) throws {
        let query = genericQuery(account: path)
        let secret = Data(passphrase.utf8)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: secret] as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = secret
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialError.keychain(status: addStatus, operation: "save a passphrase")
            }
        default:
            throw CredentialError.keychain(status: updateStatus, operation: "update a passphrase")
        }
    }

    /// Deletes a stored key passphrase.
    ///
    /// - Parameter path: Filesystem path of the key.
    /// - Throws: ``CredentialError/keychain(status:operation:)`` if the keychain refused.
    public func removePassphrase(forPrivateKeyAt path: String) throws {
        let status = SecItemDelete(genericQuery(account: path) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychain(status: status, operation: "delete a passphrase")
        }
    }

    // MARK: - Query construction

    /// The attributes identifying one connection's internet password.
    ///
    /// These four together are the item's identity, so they must be built identically for read, write,
    /// and delete — hence one function rather than three copies that can drift apart.
    private func internetQuery(for host: RemoteHost) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host.hostname,
            kSecAttrPort as String: host.port,
            kSecAttrProtocol as String: Self.protocolAttribute(for: host.protocolIdentifier),
            kSecAttrAccount as String: host.keychainAccount
        ]
    }

    /// The attributes identifying a generic password used for a key passphrase.
    private func genericQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(serviceLabelPrefix) SSH key passphrase",
            kSecAttrAccount as String: account
        ]
    }

    /// Maps a protocol to the Keychain's protocol attribute.
    ///
    /// Keychain Access shows this as the item's "Kind", and `ssh` looks for `kSecAttrProtocolSSH`
    /// specifically, so the mapping is what makes items legible outside DriverPro.
    ///
    /// - Parameter identifier: The protocol in use.
    /// - Returns: The matching `kSecAttrProtocol` constant.
    static func protocolAttribute(for identifier: ProtocolIdentifier) -> CFString {
        switch identifier {
        case .sftp: kSecAttrProtocolSSH
        case .ftp: kSecAttrProtocolFTP
        // WebDAV and S3 are both HTTPS underneath, and that is what the Keychain models.
        case .webdav, .s3: kSecAttrProtocolHTTPS
        default: kSecAttrProtocolHTTPS
        }
    }
}
