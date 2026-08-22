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

        /// The key's algorithm, such as `"ssh-ed25519"`, or `nil` if it could not be determined.
        ///
        /// Worth knowing before connecting, because not every algorithm works. An `ssh-rsa` key can only
        /// be signed with SHA-1 here, which modern servers refuse, and an ECDSA key cannot be read from a
        /// file at all — see ``supportLevel``. Telling the user that in the key picker is much kinder than
        /// letting them discover it as a login failure.
        ///
        /// `nil` for classic PEM files, whose algorithm is not recoverable without decrypting them.
        public var algorithm: String?

        /// How well DriverPro can actually use this key.
        public enum Support: Hashable, Sendable {
            /// Works.
            case supported
            /// Cannot be used this way, with a reason fit to show a person.
            case unsupported(reason: String)
            /// Might work, with a caveat worth reading first.
            case caveat(String)
        }

        /// Whether this key will work, and what to say if it will not.
        ///
        /// The reasons trace back to the SSH transport, not to the key: see
        /// `docs/decisions/014-rsa-public-key-authentication-is-unavailable.md`.
        public var supportLevel: Support {
            switch algorithm {
            case "ssh-ed25519":
                .supported
            case "ssh-rsa":
                .unsupported(reason: "RSA keys need SHA-2 signatures, which this SSH transport cannot "
                    + "offer. Use an Ed25519 key.")
            case .some(let name) where name.hasPrefix("ecdsa-"):
                .unsupported(reason: "ECDSA key files cannot be read yet. This key does work through "
                    + "ssh-agent.")
            case "ssh-dss":
                .unsupported(reason: "DSA keys are obsolete and are not supported.")
            case .some(let name) where name.hasPrefix("sk-"):
                .unsupported(reason: "Hardware-backed keys are not supported yet.")
            default:
                // Includes PEM files, whose algorithm cannot be read without decrypting them. Let the
                // attempt happen: guessing wrong in either direction would be worse than trying.
                .caveat("DriverPro cannot tell which algorithm this key uses until it connects.")
            }
        }

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
        ///   - algorithm: The key's algorithm, if it could be read.
        public init(url: URL, format: Format, isEncrypted: Bool, algorithm: String? = nil) {
            self.url = url
            self.format = format
            self.isEncrypted = isEncrypted
            self.algorithm = algorithm
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
        "id_ed25519", "id_ecdsa_sk", "id_ed25519_sk", "id_ecdsa", "id_rsa", "id_dsa",
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

    /// Classifies one key the user named, wherever it lives.
    ///
    /// ``discoverKeys()`` only looks at ``conventionalNames`` inside ``sshDirectory``; this is the other
    /// half, for a key chosen from a file picker. A key called `work-server.pem` on a USB stick is
    /// perfectly valid and must not be rejected for having an unusual name.
    ///
    /// - Parameter url: The key file.
    /// - Returns: How the key is stored and whether it needs a passphrase.
    /// - Throws: ``CredentialError/fileAccess(path:reason:)`` if the file cannot be read,
    ///   ``CredentialError/publicKeyChosen(path:)`` if it is the public half of a pair, or
    ///   ``CredentialError/unsupportedKeyFormat(path:)`` if it is not a key at all. Unlike
    ///   ``discoverKeys()``, which omits what it cannot read, this throws: the user pointed at this
    ///   exact file, so silence would be a lie.
    public func inspectKey(at url: URL) throws -> DiscoveredKey {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CredentialError.fileAccess(path: url.path, reason: error.localizedDescription)
        }
        guard let key = Self.inspect(contents: contents, at: url) else {
            // Checked only once the file is known not to be a private key, so a private key is never
            // examined twice — and so the more specific error wins over the generic one.
            throw Self.isPublicKey(contents: contents)
                ? CredentialError.publicKeyChosen(path: url.path)
                : CredentialError.unsupportedKeyFormat(path: url.path)
        }
        return key
    }

    /// Whether text is an OpenSSH *public* key, such as the contents of `id_ed25519.pub`.
    ///
    /// Reads the contents rather than the file name, because the name is not reliable in either
    /// direction: `authorized_keys` holds public keys with no `.pub` anywhere, and a private key renamed
    /// `backup.pub` is still a private key.
    ///
    /// The format is one line of `<algorithm> <base64> [comment]`, so recognising the algorithm token and
    /// finding something after it is enough. Deliberately not a full parse: this only has to be right
    /// often enough to produce a better error message than "unsupported format".
    ///
    /// - Parameter contents: The file's text.
    /// - Returns: `true` if this looks like a public key line.
    public static func isPublicKey(contents: String) -> Bool {
        guard let line = contents.split(separator: "\n").first(where: { !$0.isEmpty }) else { return false }

        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return false }

        // Every OpenSSH public key algorithm starts with one of these: `ssh-ed25519`, `ssh-rsa`,
        // `ecdsa-sha2-nistp256`, `sk-ssh-ed25519@openssh.com`, and the `-cert-v01` variants of each.
        let algorithm = fields[0]
        return algorithm.hasPrefix("ssh-") || algorithm.hasPrefix("ecdsa-") || algorithm.hasPrefix("sk-")
    }

    /// Reads a key's bytes.
    ///
    /// Deliberately separate from ``inspectKey(at:)``: classifying tells the caller whether a passphrase
    /// is needed, and that question should be settled — possibly by prompting a human — before any key
    /// material is sitting in memory waiting for an answer.
    ///
    /// - Parameter key: A key from ``discoverKeys()`` or ``inspectKey(at:)``.
    /// - Returns: The file's raw bytes, ready for ``DPCore/Credentials/Method/privateKey(data:passphrase:path:)``.
    /// - Throws: ``CredentialError/fileAccess(path:reason:)`` if the file cannot be read.
    public func read(_ key: DiscoveredKey) throws -> Data {
        do {
            return try Data(contentsOf: key.url)
        } catch {
            throw CredentialError.fileAccess(path: key.url.path, reason: error.localizedDescription)
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
                isEncrypted: isOpenSSHKeyEncrypted(contents: contents),
                algorithm: openSSHAlgorithm(contents: contents)
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
    /// Reads the algorithm name out of an OpenSSH-format key.
    ///
    /// Read from the *public* half, which the format stores in the clear even for an encrypted key — so
    /// this works without a passphrase, which is the whole reason it is worth doing here. The layout after
    /// the magic string is:
    ///
    /// ```
    /// string  ciphername
    /// string  kdfname
    /// string  kdfoptions
    /// uint32  number of keys
    /// string  publickey        ← itself string(algorithm) followed by algorithm-specific bytes
    /// ```
    ///
    /// - Parameter contents: The full text of the key file.
    /// - Returns: The algorithm name, or `nil` if the body cannot be parsed. `nil` means "do not know",
    ///   never "unsupported" — the caller treats the two very differently.
    static func openSSHAlgorithm(contents: String) -> String? {
        let base64 = contents
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()

        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        let magic = Data("openssh-key-v1\0".utf8)
        guard data.count > magic.count, data.prefix(magic.count) == magic else { return nil }

        var reader = ByteReader(data.dropFirst(magic.count))
        for _ in 0..<3 {                                    // ciphername, kdfname, kdfoptions
            guard reader.readSSHString() != nil else { return nil }
        }
        guard reader.readUInt32() != nil, let publicKey = reader.readSSHString() else { return nil }

        return HostKeyFingerprint.algorithmName(ofKeyBlob: publicKey)
    }

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
