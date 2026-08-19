//
//  PrivateKeyLocatorTests.swift
//  DPCredentialsTests
//

import Foundation
import Testing
@testable import DPCredentials

@Suite("PrivateKeyLocator")
struct PrivateKeyLocatorTests {

    private let anyURL = URL(fileURLWithPath: "/Users/test/.ssh/id_ed25519")

    @Test("An unencrypted OpenSSH key needs no passphrase")
    func detectsUnencryptedOpenSSHKey() throws {
        let key = try #require(PrivateKeyLocator.inspect(contents: Fixtures.unencryptedOpenSSHKey, at: anyURL))
        #expect(key.format == .openSSH)
        #expect(!key.isEncrypted)
    }

    @Test("An encrypted OpenSSH key is detected from its cipher field")
    func detectsEncryptedOpenSSHKey() throws {
        // The headers of the two OpenSSH fixtures are byte-identical — the difference is `aes256-ctr`
        // versus `none` inside the base64 body. Searching the text for "ENCRYPTED" finds nothing here,
        // which is precisely the bug this test exists to prevent.
        let key = try #require(PrivateKeyLocator.inspect(contents: Fixtures.encryptedOpenSSHKey, at: anyURL))
        #expect(key.format == .openSSH)
        #expect(key.isEncrypted)
    }

    @Test("The two OpenSSH fixtures really do have identical headers")
    func headersAreIndistinguishable() {
        let firstLine = { (text: String) in String(text.split(separator: "\n")[0]) }
        #expect(firstLine(Fixtures.unencryptedOpenSSHKey) == firstLine(Fixtures.encryptedOpenSSHKey))
    }

    @Test("A classic PEM key advertises encryption in the clear")
    func detectsEncryptedPEM() throws {
        let key = try #require(PrivateKeyLocator.inspect(contents: Fixtures.encryptedPEMKey, at: anyURL))
        #expect(key.format == .pem)
        #expect(key.isEncrypted)
    }

    @Test("Text that is not a private key is rejected", arguments: [
        "",
        "just some text",
        "ssh-ed25519 AAAAC3Nz… user@host",          // a *public* key
        "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
    ])
    func rejectsNonKeys(_ contents: String) {
        #expect(PrivateKeyLocator.inspect(contents: contents, at: anyURL) == nil)
    }

    @Test("A truncated OpenSSH body is treated as unencrypted rather than crashing")
    func handlesTruncatedBody() throws {
        // Reading a length field from bytes that are not there is exactly how a parser reads past the
        // end of a buffer. Returning false is the safe answer: attempting without a passphrase gives a
        // clearer error than prompting for one that may not be needed.
        let truncated = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3Bl\n-----END OPENSSH PRIVATE KEY-----"
        let key = try #require(PrivateKeyLocator.inspect(contents: truncated, at: anyURL))
        #expect(!key.isEncrypted)
    }

    // MARK: - Discovery

    @Test("Discovery finds conventional key names and ignores everything else")
    func discoversConventionalKeys() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Fixtures.unencryptedOpenSSHKey.write(
            to: directory.appendingPathComponent("id_ed25519"), atomically: true, encoding: .utf8)
        try Fixtures.encryptedPEMKey.write(
            to: directory.appendingPathComponent("id_rsa"), atomically: true, encoding: .utf8)
        // Files that live in ~/.ssh but are not private keys.
        try "ssh-ed25519 AAAA test".write(
            to: directory.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)
        try "Host *\n  User me".write(
            to: directory.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let keys = PrivateKeyLocator(sshDirectory: directory).discoverKeys()

        #expect(keys.count == 2)
        // Ed25519 first: the order is what the key picker offers, and the stronger algorithm should be
        // the default suggestion.
        #expect(keys.map(\.name) == ["id_ed25519", "id_rsa"])
        #expect(keys[0].isEncrypted == false)
        #expect(keys[1].isEncrypted == true)
    }

    @Test("A directory with no keys yields an empty list, not an error")
    func emptyDirectory() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(PrivateKeyLocator(sshDirectory: missing).discoverKeys().isEmpty)
    }

    // MARK: - Algorithm

    @Test("The algorithm is read from an OpenSSH key's public half")
    func readsTheAlgorithm() throws {
        // Stored in the clear even in an encrypted key, which is what makes it readable without a
        // passphrase — and therefore usable to warn the user before they try to connect.
        let key = try #require(PrivateKeyLocator.inspect(contents: Fixtures.unencryptedOpenSSHKey, at: anyURL))
        #expect(key.algorithm == "ssh-ed25519")
        #expect(key.supportLevel == .supported)
    }

    @Test("A PEM key's algorithm is unknown, which is not the same as unsupported")
    func pemAlgorithmIsUnknown() throws {
        // It cannot be read without decrypting the file. Guessing would be worse than admitting it: the
        // caveat lets the attempt proceed, where `unsupported` would block a key that may work perfectly.
        let key = try #require(PrivateKeyLocator.inspect(contents: Fixtures.encryptedPEMKey, at: anyURL))
        #expect(key.algorithm == nil)
        guard case .caveat = key.supportLevel else {
            Issue.record("expected a caveat, got \(key.supportLevel)")
            return
        }
    }

    @Test("Algorithms this transport cannot use say so, and say what to do instead", arguments: [
        ("ssh-rsa", "Ed25519"),
        ("ecdsa-sha2-nistp256", "ssh-agent"),
        ("ssh-dss", "obsolete"),
        ("sk-ssh-ed25519@openssh.com", "Hardware")
    ])
    func unsupportedAlgorithmsExplainThemselves(algorithm: String, expectedAdvice: String) throws {
        // The RSA case is the one that matters in practice: `id_rsa` is still the most common key on older
        // machines, and it cannot work here. See ADR 014.
        let key = PrivateKeyLocator.DiscoveredKey(
            url: anyURL, format: .openSSH, isEncrypted: false, algorithm: algorithm)

        guard case .unsupported(let reason) = key.supportLevel else {
            Issue.record("\(algorithm) should be unsupported, got \(key.supportLevel)")
            return
        }
        #expect(reason.contains(expectedAdvice), "the reason should point somewhere: \(reason)")
    }

    @Test("A body that cannot be parsed yields no algorithm rather than a wrong one")
    func unparseableBodyHasNoAlgorithm() throws {
        let truncated = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3Bl\n-----END OPENSSH PRIVATE KEY-----"
        let key = try #require(PrivateKeyLocator.inspect(contents: truncated, at: anyURL))
        #expect(key.algorithm == nil)
    }

    // MARK: - A key the user named

    /// Writes `contents` to a throwaway file and hands back its URL.
    private func temporaryFile(named name: String, contents: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("A key chosen by hand is accepted whatever it is called")
    func inspectsAKeyOutsideTheConventionalNames() throws {
        // `discoverKeys` would never find this one. A key called `work-server.pem` is perfectly valid
        // and must not be rejected for having an unusual name.
        let url = try temporaryFile(named: "work-server.pem", contents: Fixtures.encryptedOpenSSHKey)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let key = try PrivateKeyLocator().inspectKey(at: url)
        #expect(key.format == .openSSH)
        #expect(key.isEncrypted)
        #expect(key.id == url.path, "the path is the identity, and the Keychain account")
    }

    @Test("A key the user named but that cannot be read is an error, not a silent omission")
    func inspectingAMissingKeyThrows() {
        // `discoverKeys` omits what it cannot read, because a broken file in ~/.ssh is not something a
        // connection dialog can act on. Here the user pointed at this exact file, so silence would lie.
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/id_ed25519")
        #expect(throws: CredentialError.self) {
            try PrivateKeyLocator().inspectKey(at: missing)
        }
    }

    @Test("A file that is not a private key at all reports the format, not the access")
    func inspectingANonKeyReportsTheFormat() throws {
        let url = try temporaryFile(named: "notes.txt", contents: "shopping list")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(throws: CredentialError.unsupportedKeyFormat(path: url.path)) {
            try PrivateKeyLocator().inspectKey(at: url)
        }
    }

    // MARK: - The wrong half of the pair

    @Test("Picking the .pub file says so, rather than calling it an unsupported format")
    func inspectingAPublicKeySaysWhichHalf() throws {
        // The mistake people actually make: `id_ed25519` and `id_ed25519.pub` sit side by side with nearly
        // the same name. "Unsupported format" would send them looking for a conversion tool.
        let url = try temporaryFile(named: "id_ed25519.pub", contents: Fixtures.publicKeyLine)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let error = try #require(#expect(throws: CredentialError.self) {
            try PrivateKeyLocator().inspectKey(at: url)
        })
        #expect(error == .publicKeyChosen(path: url.path))

        let message = try #require(error.errorDescription)
        #expect(message.contains("private half"), "the message has to say what to pick instead")
    }

    @Test("A public key is recognised by its contents, not by being called .pub")
    func recognisesAPublicKeyWithoutTheExtension() throws {
        // `authorized_keys` holds public keys with no `.pub` anywhere, and a private key renamed
        // `backup.pub` is still a private key. The name settles neither question.
        let url = try temporaryFile(named: "authorized_keys", contents: Fixtures.publicKeyLine)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(throws: CredentialError.publicKeyChosen(path: url.path)) {
            try PrivateKeyLocator().inspectKey(at: url)
        }
    }

    @Test("A private key misnamed .pub is still a private key")
    func aPrivateKeyNamedPubIsStillPrivate() throws {
        let url = try temporaryFile(named: "backup.pub", contents: Fixtures.unencryptedOpenSSHKey)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(try PrivateKeyLocator().inspectKey(at: url).format == .openSSH)
    }

    @Test("Public key detection accepts the algorithms OpenSSH emits", arguments: [
        "ssh-ed25519 AAAAC3Nz user@host",
        "ssh-rsa AAAAB3Nz user@host",
        "ecdsa-sha2-nistp256 AAAAE2Vj user@host",
        "sk-ssh-ed25519@openssh.com AAAAGnNr user@host",
        "ssh-ed25519 AAAAC3Nz"                              // a comment is optional
    ])
    func detectsPublicKeyLines(_ line: String) {
        #expect(PrivateKeyLocator.isPublicKey(contents: line))
    }

    @Test("Public key detection is not fooled by prose or by a private key", arguments: [
        "",
        "shopping list",
        "ssh-ed25519",                                       // an algorithm with nothing after it
        "-----BEGIN OPENSSH PRIVATE KEY-----\nb3Bl\n-----END OPENSSH PRIVATE KEY-----"
    ])
    func doesNotSeePublicKeysEverywhere(_ contents: String) {
        #expect(!PrivateKeyLocator.isPublicKey(contents: contents))
    }

    @Test("Reading a key hands back its bytes verbatim")
    func readsKeyBytes() throws {
        let url = try temporaryFile(named: "id_ed25519", contents: Fixtures.unencryptedOpenSSHKey)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let locator = PrivateKeyLocator()
        let data = try locator.read(locator.inspectKey(at: url))
        #expect(data == Data(Fixtures.unencryptedOpenSSHKey.utf8))
    }

    @Test("Reading a key that has since gone reports file access")
    func readingAVanishedKeyThrows() throws {
        let url = try temporaryFile(named: "id_ed25519", contents: Fixtures.unencryptedOpenSSHKey)
        let locator = PrivateKeyLocator()
        let key = try locator.inspectKey(at: url)
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())

        #expect(throws: CredentialError.self) { try locator.read(key) }
    }
}
