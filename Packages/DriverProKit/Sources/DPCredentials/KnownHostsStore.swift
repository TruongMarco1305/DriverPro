//
//  KnownHostsStore.swift
//  DPCredentials
//

import CryptoKit
import Foundation

// MARK: - Trust outcome

/// What `~/.ssh/known_hosts` has to say about a server's key.
///
/// The distinction between ``unknown`` and ``mismatch(storedFingerprint:)`` is the entire reason this
/// type exists. The first is routine — every server is new once. The second means the key changed, which
/// is either a legitimately rebuilt server or somebody sitting in the middle of the connection. Collapsing
/// them into a single "please confirm" prompt trains users to click Accept, which is how the attack
/// succeeds.
public enum HostKeyTrust: Hashable, Sendable {
    /// No key on record for this host. Trust on first use: show the fingerprint and let the user decide.
    case unknown

    /// This exact key is already on record. Connect without prompting.
    case trusted

    /// A key of this algorithm is on record and **differs**. Carries the stored key's fingerprint so the
    /// prompt can show old and new side by side.
    case mismatch(storedFingerprint: String)

    /// The key is explicitly marked `@revoked`. Never prompt; refuse.
    case revoked
}

// MARK: - Entry

/// A single parsed line of a `known_hosts` file.
public struct KnownHostsEntry: Hashable, Sendable {

    /// An optional marker at the start of a line.
    public enum Marker: String, Hashable, Sendable {
        /// A normal entry.
        case none = ""
        /// `@revoked` — this key must never be accepted.
        case revoked = "@revoked"
        /// `@cert-authority` — the key signs host certificates rather than being a host key itself.
        case certAuthority = "@cert-authority"
    }

    /// How a line names the hosts it applies to.
    public enum HostPattern: Hashable, Sendable {
        /// A literal name or glob, such as `example.com`, `[localhost]:2222`, or `*.example.com`.
        case plain(String)

        /// A hashed name: `|1|salt|hash`, where hash is HMAC-SHA1 of the host pattern keyed by the salt.
        ///
        /// This is the **default** for modern OpenSSH (`HashKnownHosts yes`), so a parser that only
        /// understands plain entries matches nothing on a typical machine and re-prompts for every host
        /// the user already trusts.
        case hashed(salt: Data, hash: Data)
    }

    /// The line's marker.
    public var marker: Marker
    /// The hosts this line applies to.
    public var hostPatterns: [HostPattern]
    /// The key algorithm, such as `"ssh-ed25519"`.
    public var keyType: String
    /// The raw public key blob.
    public var keyBlob: Data

    /// Creates an entry.
    ///
    /// - Parameters:
    ///   - marker: The line's marker.
    ///   - hostPatterns: Hosts this entry applies to.
    ///   - keyType: The key algorithm name.
    ///   - keyBlob: The raw public key blob.
    public init(marker: Marker, hostPatterns: [HostPattern], keyType: String, keyBlob: Data) {
        self.marker = marker
        self.hostPatterns = hostPatterns
        self.keyType = keyType
        self.keyBlob = keyBlob
    }

    // MARK: Parsing

    /// Parses one line of a `known_hosts` file.
    ///
    /// Returns `nil` for blank lines, comments, and lines that cannot be understood. Unparseable lines
    /// are skipped rather than thrown on: a single line written by some other tool must not make the
    /// whole file unreadable and lock the user out of every host they trust.
    ///
    /// - Parameter line: One line of the file, without its newline.
    /// - Returns: The parsed entry, or `nil` if the line carries no key.
    public static func parse(line: String) -> KnownHostsEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        var fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)

        // An optional marker comes first and shifts every other field along by one.
        var marker = Marker.none
        if let first = fields.first, first.hasPrefix("@") {
            guard let parsed = Marker(rawValue: first) else { return nil }
            marker = parsed
            fields.removeFirst()
        }

        // hosts, key-type, base64-key, [comment]
        guard fields.count >= 3 else { return nil }

        let patterns = fields[0].split(separator: ",").map { field -> HostPattern in
            parseHashedPattern(String(field)) ?? .plain(String(field))
        }
        guard !patterns.isEmpty else { return nil }

        let keyType = fields[1]
        guard let keyBlob = Data(base64Encoded: fields[2]), keyBlob.count >= 8 else { return nil }

        return KnownHostsEntry(marker: marker, hostPatterns: patterns, keyType: keyType, keyBlob: keyBlob)
    }

    /// Parses a `|1|salt|hash` pattern, or returns `nil` if the field is not in hashed form.
    private static func parseHashedPattern(_ field: String) -> HostPattern? {
        // Format: |1|<base64 salt>|<base64 hash>. The "1" is the only defined hash type (HMAC-SHA1).
        guard field.hasPrefix("|1|") else { return nil }

        let parts = field.dropFirst(3).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let salt = Data(base64Encoded: String(parts[0])),
              let hash = Data(base64Encoded: String(parts[1]))
        else { return nil }

        return .hashed(salt: salt, hash: hash)
    }

    // MARK: Matching

    /// Reports whether this entry applies to the given host pattern string.
    ///
    /// - Parameter hostPattern: The canonical host string, from ``KnownHostsStore/hostPattern(host:port:)``.
    /// - Returns: `true` if any of this entry's patterns matches.
    public func matches(hostPattern: String) -> Bool {
        hostPatterns.contains { pattern in
            switch pattern {
            case .plain(let stored):
                // A leading "!" negates a pattern. Treated as "does not apply" rather than as an active
                // denial, which is a simplification: full OpenSSH semantics let a negation veto an
                // earlier match on the same line. Rare enough in practice to be worth the simpler rule.
                if stored.hasPrefix("!") { return false }
                return Self.glob(pattern: stored, matches: hostPattern)

            case .hashed(let salt, let hash):
                return Self.hashedHostMatches(hostPattern, salt: salt, expectedHash: hash)
            }
        }
    }

    /// Computes HMAC-SHA1 of a host pattern under a salt and compares it to the stored hash.
    ///
    /// SHA-1 is broken for collision resistance but this is HMAC over a value we already know, used
    /// only to look up a row. OpenSSH defines the format; matching it is the requirement.
    /// `CryptoKit.Insecure` is where Apple keeps such algorithms, and the name is a deliberate speed bump.
    private static func hashedHostMatches(_ hostPattern: String, salt: Data, expectedHash: Data) -> Bool {
        let key = SymmetricKey(data: salt)
        let computed = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(hostPattern.utf8),
            using: key
        )
        return Data(computed) == expectedHash
    }

    /// Matches a shell-style glob supporting `*` and `?`.
    ///
    /// Written out rather than delegating to `fnmatch` so the behaviour is identical on every platform
    /// and testable without a filesystem.
    static func glob(pattern: String, matches subject: String) -> Bool {
        guard pattern.contains("*") || pattern.contains("?") else { return pattern == subject }

        let patternChars = Array(pattern)
        let subjectChars = Array(subject)

        // Classic two-pointer wildcard match with backtracking on the most recent `*`.
        var patternIndex = 0, subjectIndex = 0
        var starIndex = -1, matchIndex = 0

        while subjectIndex < subjectChars.count {
            if patternIndex < patternChars.count,
               patternChars[patternIndex] == "?" || patternChars[patternIndex] == subjectChars[subjectIndex] {
                patternIndex += 1
                subjectIndex += 1
            } else if patternIndex < patternChars.count, patternChars[patternIndex] == "*" {
                starIndex = patternIndex
                matchIndex = subjectIndex
                patternIndex += 1
            } else if starIndex != -1 {
                patternIndex = starIndex + 1
                matchIndex += 1
                subjectIndex = matchIndex
            } else {
                return false
            }
        }

        while patternIndex < patternChars.count, patternChars[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternChars.count
    }
}

// MARK: - Store

/// Reads and appends `~/.ssh/known_hosts`.
///
/// The file is shared with OpenSSH rather than kept privately, so a host already trusted in Terminal
/// does not prompt again here, and accepting a key here is honoured by `ssh` afterwards. See
/// `docs/decisions/004-known-hosts-and-keychain.md`.
///
/// ## Swift note — `actor` for file access
/// An actor rather than a struct of static functions because appends must not interleave. Two sessions
/// connecting to two new hosts at once would otherwise race on the same file. Reads are serialised too,
/// which costs nothing at this scale — the file is a few kilobytes and is read once per connection.
public actor KnownHostsStore {

    /// The file being read and appended.
    ///
    /// `nonisolated` because it is immutable: reading it touches no protected state, so callers should
    /// not have to `await` merely to name the file in a log message.
    public nonisolated let fileURL: URL

    /// Creates a store over a `known_hosts` file.
    ///
    /// - Parameter fileURL: The file to use. Defaults to `~/.ssh/known_hosts`.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/known_hosts")
    }

    // MARK: Host naming

    /// The canonical string OpenSSH uses to name a host in `known_hosts`.
    ///
    /// The default SSH port is written bare; any other port is bracketed — `[localhost]:2222`. Getting
    /// this wrong means never matching an entry for a non-standard port, so it is exercised by the
    /// integration tests, which run against port 2222.
    ///
    /// - Parameters:
    ///   - host: The host name or address.
    ///   - port: The port connected to.
    /// - Returns: The canonical pattern string.
    public nonisolated static func hostPattern(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    // MARK: Querying

    /// Loads and parses the file.
    ///
    /// A missing file is not an error — it means no host has been trusted yet, which is the normal state
    /// on a fresh account.
    ///
    /// - Returns: Every entry that parsed, in file order.
    /// - Throws: ``CredentialError/fileAccess(path:reason:)`` if the file exists but cannot be read.
    public func entries() throws -> [KnownHostsEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let contents: String
        do {
            contents = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw CredentialError.fileAccess(path: fileURL.path, reason: error.localizedDescription)
        }

        return contents.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { KnownHostsEntry.parse(line: String($0)) }
    }

    /// Decides what the file says about a server's key.
    ///
    /// The precedence deliberately puts revocation first: a revoked key must be refused even if some
    /// other line also lists it as valid.
    ///
    /// - Parameters:
    ///   - host: The host name connected to.
    ///   - port: The port connected to.
    ///   - keyBlob: The key the server presented.
    /// - Returns: Whether the key is unknown, trusted, changed, or revoked.
    /// - Throws: ``CredentialError/fileAccess(path:reason:)`` if the file cannot be read.
    public func trust(host: String, port: Int, keyBlob: Data) throws -> HostKeyTrust {
        let pattern = Self.hostPattern(host: host, port: port)
        let applicable = try entries().filter { $0.matches(hostPattern: pattern) }

        if applicable.contains(where: { $0.marker == .revoked && $0.keyBlob == keyBlob }) {
            return .revoked
        }
        if applicable.contains(where: { $0.marker == .none && $0.keyBlob == keyBlob }) {
            return .trusted
        }

        // A key of the same algorithm that does not match is a changed key. A *different* algorithm is
        // not: servers legitimately offer several host keys, and meeting the Ed25519 key of a host we
        // only knew by RSA is a first contact, not an attack.
        let algorithm = HostKeyFingerprint.algorithmName(ofKeyBlob: keyBlob)
        if let conflicting = applicable.first(where: { $0.marker == .none && $0.keyType == algorithm }) {
            return .mismatch(storedFingerprint: HostKeyFingerprint.sha256(ofKeyBlob: conflicting.keyBlob))
        }

        return .unknown
    }

    // MARK: Appending

    /// Appends a host key to the file, creating it and `~/.ssh` if needed.
    ///
    /// Everything already in the file is preserved byte for byte.
    ///
    /// - Parameters:
    ///   - host: The host name to record.
    ///   - port: The port, which decides whether the name is bracketed.
    ///   - keyBlob: The key to trust.
    /// - Throws: ``CredentialError/fileAccess(path:reason:)`` if the file cannot be written, or
    ///   ``CredentialError/unsupportedKeyFormat(path:)`` if the blob has no readable algorithm name.
    public func append(host: String, port: Int, keyBlob: Data) throws {
        guard let algorithm = HostKeyFingerprint.algorithmName(ofKeyBlob: keyBlob) else {
            throw CredentialError.unsupportedKeyFormat(path: fileURL.path)
        }

        let line = "\(Self.hostPattern(host: host, port: port)) \(algorithm) \(keyBlob.base64EncodedString())\n"
        try createDirectoryIfNeeded()
        try appendAtomically(Data(line.utf8))
    }

    /// Creates `~/.ssh` with mode 700 if it does not exist.
    ///
    /// The permissions matter: OpenSSH refuses to use a `.ssh` directory that others can write to, so
    /// creating it loosely would break `ssh` itself.
    private func createDirectoryIfNeeded() throws {
        let directory = fileURL.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CredentialError.fileAccess(path: directory.path, reason: error.localizedDescription)
        }
    }

    /// Appends bytes using `O_APPEND`, so a concurrent `ssh` cannot be clobbered.
    ///
    /// ## Swift note — calling POSIX from Swift
    /// `FileHandle` has no append mode: the usual `seekToEnd` then `write` is two operations, and another
    /// process writing in between makes the seek stale, overwriting its line. `O_APPEND` moves the offset
    /// and writes as one atomic step at the kernel level, which is exactly the guarantee needed when the
    /// file is shared with OpenSSH.
    ///
    /// Swift calls these C functions directly. Two details worth noting: `defer { close(descriptor) }`
    /// guarantees the file descriptor is released on every exit path including a thrown error, and
    /// `withUnsafeBytes` hands C a pointer into `Data`'s storage that is valid only for the duration of
    /// the closure — returning it would be a dangling pointer.
    private func appendAtomically(_ data: Data) throws {
        let descriptor = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            throw CredentialError.fileAccess(path: fileURL.path, reason: String(cString: strerror(errno)))
        }
        defer { close(descriptor) }

        let written = data.withUnsafeBytes { buffer in
            write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == data.count else {
            throw CredentialError.fileAccess(path: fileURL.path, reason: "short write")
        }
    }
}
