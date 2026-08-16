//
//  PrivateKeyLocator.swift
//  DPCredentials
//

import Foundation

/// Finds SSH private keys in `~/.ssh` and works out whether they need a passphrase.
///
/// The passphrase question is the point. Prompting for one when the key is unencrypted is confusing;
/// *not* prompting when it is encrypted produces an authentication failure with no explanation. So the
/// file is inspected rather than guessed at.
public struct PrivateKeyLocator: Sendable {

    // MARK: - Discovered key

    /// A private key found on disk.
    public struct DiscoveredKey: Hashable, Sendable, Identifiable {

        /// The container format the key is stored in.
        public enum Format: Hashable, Sendable {
            /// OpenSSH's own format, `-----BEGIN OPENSSH PRIVATE KEY-----`. The default since 2017.
            case openSSH
            /// Classic PEM, `-----BEGIN RSA PRIVATE KEY-----` and friends.
            case pem
        }

        /// Where the key file is.
        public var url: URL
        /// The container format.
        public var format: Format
        /// Whether a passphrase is needed to use it.
        public var isEncrypted: Bool

        /// The file's path, used as its identity and as its Keychain account.
        public var id: String { url.path }

        /// The file name, for display in a key picker.
        public var name: String { url.lastPathComponent }

        /// Creates a discovered key.
        ///
        /// - Parameters:
        ///   - url: Location of the key file.
        ///   - format: The container format.
        ///   - isEncrypted: Whether a passphrase is required.
        public init(url: URL, format: Format, isEncrypted: Bool) {
            self.url = url
            self.format = format
            self.isEncrypted = isEncrypted
        }
    }

    // MARK: - Configuration

    /// The directory to search.
    public let sshDirectory: URL

    /// Creates a locator.
    ///
    /// - Parameter sshDirectory: Directory to search. Defaults to `~/.ssh`.
    public init(sshDirectory: URL? = nil) {
        self.sshDirectory = sshDirectory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
    }

    /// Key file names OpenSSH tries by default, strongest algorithm first.
    ///
    /// Ordering matters: it is the order the key picker offers them in, and Ed25519 should be the
    /// default suggestion over RSA.
    public static let conventionalNames = [
        "id_ed25519", "id_ecdsa_sk", "id_ed25519_sk", "id_ecdsa", "id_rsa", "id_dsa"
    ]

    // MARK: - Discovery

    /// Finds private keys in the search directory.
    ///
    /// Only files matching OpenSSH's conventional names are considered, and `.pub` files are skipped —
    /// scanning every file in `~/.ssh` would pick up `config`, `known_hosts`, and any unrelated content.
    ///
    /// A key whose contents cannot be read is omitted rather than reported: an unreadable file is not
    /// something the user can act on from a connection dialog.
    ///
    /// - Returns: The keys found, in ``conventionalNames`` order.
    public func discoverKeys() -> [DiscoveredKey] {
        Self.conventionalNames.compactMap { name in
            let url = sshDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path),
                  let contents = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            return Self.inspect(contents: contents, at: url)
        }
    }

    /// Classifies a key file's contents.
    ///
    /// - Parameters:
    ///   - contents: The file's text.
    ///   - url: Where it came from, carried into the result.
    /// - Returns: The classified key, or `nil` if the text is not a private key at all.
    public static func inspect(contents: String, at url: URL) -> DiscoveredKey? {
        if contents.contains("-----BEGIN OPENSSH PRIVATE KEY-----") {
            return DiscoveredKey(
                url: url,
                format: .openSSH,
                isEncrypted: isOpenSSHKeyEncrypted(contents: contents)
            )
        }

        guard contents.contains("-----BEGIN"), contents.contains("PRIVATE KEY-----") else { return nil }

        // Classic PEM advertises encryption in the clear, either as a header or in the BEGIN line.
        let isEncrypted = contents.contains("Proc-Type: 4,ENCRYPTED")
            || contents.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----")
        return DiscoveredKey(url: url, format: .pem, isEncrypted: isEncrypted)
    }

    // MARK: - OpenSSH format

    /// Determines whether an OpenSSH-format key is encrypted.
    ///
    /// The format carries no `ENCRYPTED` marker in its text — the header is identical either way — so
    /// the base64 body must actually be decoded. Its layout is:
    ///
    /// ```
    /// "openssh-key-v1\0"          15 bytes, a NUL-terminated magic string
    /// string  ciphername          4-byte big-endian length, then that many bytes
    /// string  kdfname
    /// …
    /// ```
    ///
    /// The cipher name is `"none"` for an unencrypted key and something like `"aes256-ctr"` otherwise.
    ///
    /// - Parameter contents: The full text of the key file.
    /// - Returns: `true` if a passphrase is required. Returns `false` when the body cannot be parsed,
    ///   since attempting without a passphrase produces a clearer error than prompting for one that may
    ///   not be needed.
    static func isOpenSSHKeyEncrypted(contents: String) -> Bool {
        let base64 = contents
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()

        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return false
        }

        let magic = Data("openssh-key-v1\0".utf8)
        guard data.count > magic.count, data.prefix(magic.count) == magic else { return false }

        // Read the first SSH string after the magic: a 4-byte big-endian length, then the bytes.
        let body = data.dropFirst(magic.count)
        guard body.count >= 4 else { return false }

        let length = body.prefix(4).reduce(into: UInt32(0)) { $0 = ($0 << 8) | UInt32($1) }
        guard length > 0, length <= 64, body.count >= 4 + Int(length) else { return false }

        let cipherName = String(decoding: body.dropFirst(4).prefix(Int(length)), as: UTF8.self)
        return cipherName != "none"
    }
}
