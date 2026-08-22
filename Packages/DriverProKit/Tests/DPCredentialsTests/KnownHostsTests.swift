//
//  KnownHostsTests.swift
//  DPCredentialsTests
//

import Foundation
import Testing
@testable import DPCredentials

@Suite("HostKeyFingerprint")
struct HostKeyFingerprintTests {

    @Test("Fingerprint matches what ssh-keygen -lf prints")
    func matchesSSHKeygen() {
        // The one assertion in this file that really matters. If our string differs from OpenSSH's by
        // so much as a padding character, the host key prompt asks users to compare two things that
        // will never be equal, and they learn to click Accept without looking.
        #expect(HostKeyFingerprint.sha256(ofKeyBlob: Fixtures.publicKeyBlob) == Fixtures.expectedFingerprint)
    }

    @Test("Base64 padding is stripped, matching OpenSSH")
    func stripsPadding() {
        #expect(!Fixtures.expectedFingerprint.contains("="))
        #expect(Fixtures.expectedFingerprint.hasPrefix("SHA256:"))
    }

    @Test("Algorithm name is read from inside the blob")
    func readsAlgorithmName() {
        #expect(HostKeyFingerprint.algorithmName(ofKeyBlob: Fixtures.publicKeyBlob) == "ssh-ed25519")
        #expect(HostKeyFingerprint.algorithmName(ofKeyBlob: Data([0, 0])) == nil)
        // A length field larger than the data must not read past the end.
        #expect(HostKeyFingerprint.algorithmName(ofKeyBlob: Data([0, 0, 0, 99, 1, 2])) == nil)
    }
}

@Suite("known_hosts parsing")
struct KnownHostsEntryTests {

    @Test("Blank lines and comments carry no entry", arguments: ["", "   ", "# comment", "  # indented"])
    func skipsNonEntries(_ line: String) {
        #expect(KnownHostsEntry.parse(line: line) == nil)
    }

    @Test("A plain entry parses into host, type, and key")
    func parsesPlainEntry() throws {
        let entry = try #require(KnownHostsEntry.parse(line: "example.com ssh-ed25519 \(Fixtures.publicKeyBase64)"))
        #expect(entry.marker == .none)
        #expect(entry.keyType == "ssh-ed25519")
        #expect(entry.keyBlob == Fixtures.publicKeyBlob)
        #expect(entry.matches(hostPattern: "example.com"))
        #expect(!entry.matches(hostPattern: "evil.com"))
    }

    @Test("Comma-separated host lists all match")
    func parsesMultipleHosts() throws {
        let entry = try #require(
            KnownHostsEntry.parse(line: "a.com,b.com,1.2.3.4 ssh-ed25519 \(Fixtures.publicKeyBase64)")
        )
        #expect(entry.matches(hostPattern: "a.com"))
        #expect(entry.matches(hostPattern: "b.com"))
        #expect(entry.matches(hostPattern: "1.2.3.4"))
        #expect(!entry.matches(hostPattern: "c.com"))
    }

    @Test("Markers are recognised and shift the remaining fields")
    func parsesMarkers() throws {
        let revoked = try #require(
            KnownHostsEntry.parse(line: "@revoked example.com ssh-ed25519 \(Fixtures.publicKeyBase64)")
        )
        #expect(revoked.marker == .revoked)
        #expect(revoked.keyType == "ssh-ed25519")
        #expect(revoked.matches(hostPattern: "example.com"))

        let ca = try #require(
            KnownHostsEntry.parse(line: "@cert-authority *.example.com ssh-ed25519 \(Fixtures.publicKeyBase64)")
        )
        #expect(ca.marker == .certAuthority)
    }

    @Test("Wildcards match the way OpenSSH's do")
    func globMatching() {
        #expect(KnownHostsEntry.glob(pattern: "*.example.com", matches: "host.example.com"))
        #expect(KnownHostsEntry.glob(pattern: "*.example.com", matches: "a.b.example.com"))
        #expect(!KnownHostsEntry.glob(pattern: "*.example.com", matches: "example.com"))
        #expect(KnownHostsEntry.glob(pattern: "host?.test", matches: "host1.test"))
        #expect(!KnownHostsEntry.glob(pattern: "host?.test", matches: "host12.test"))
        #expect(KnownHostsEntry.glob(pattern: "*", matches: "anything"))
        #expect(KnownHostsEntry.glob(pattern: "exact.com", matches: "exact.com"))
    }

    @Test("Hashed entries match the host they were generated from")
    func parsesHashedEntries() throws {
        // These lines came out of `ssh-keygen -H`, so this asserts agreement with OpenSSH's HMAC-SHA1
        // scheme rather than with our own idea of it. Modern OpenSSH hashes by default, so getting this
        // wrong means never recognising a host the user already trusts.
        let lines = Fixtures.hashedKnownHosts.split(separator: "\n").map(String.init)

        let first = try #require(KnownHostsEntry.parse(line: lines[0]))
        #expect(first.matches(hostPattern: "example.com"))
        #expect(!first.matches(hostPattern: "elsewhere.com"))

        let second = try #require(KnownHostsEntry.parse(line: lines[1]))
        #expect(second.matches(hostPattern: "[localhost]:2222"))
        // The bracketed form is not interchangeable with the bare one.
        #expect(!second.matches(hostPattern: "localhost"))
    }

    @Test("Malformed lines are skipped, not thrown on", arguments: [
        "example.com",                                  // no key
        "example.com ssh-ed25519",                      // no base64
        "example.com ssh-ed25519 !!!not-base64!!!",     // undecodable
        "@bogus example.com ssh-ed25519 AAAA",          // unknown marker
        "|1|onlyonepart ssh-ed25519 AAAA",               // truncated hash
    ])
    func skipsMalformedLines(_ line: String) {
        // One bad line written by some other tool must not make the whole file unreadable and lock the
        // user out of every host they trust.
        #expect(KnownHostsEntry.parse(line: line) == nil)
    }
}

@Suite("KnownHostsStore")
struct KnownHostsStoreTests {

    /// A store over a fresh temporary file, plus the file's URL.
    private func makeStore(contents: String? = nil) throws -> (KnownHostsStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("known_hosts-\(UUID().uuidString)")
        if let contents {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return (KnownHostsStore(fileURL: url), url)
    }

    @Test("Port 22 is written bare; any other port is bracketed")
    func hostPatternFormat() {
        #expect(KnownHostsStore.hostPattern(host: "example.com", port: 22) == "example.com")
        #expect(KnownHostsStore.hostPattern(host: "localhost", port: 2222) == "[localhost]:2222")
    }

    @Test("A missing file means nothing is trusted yet, not an error")
    func missingFileIsEmpty() async throws {
        let (store, _) = try makeStore()
        #expect(try await store.entries().isEmpty)
        #expect(try await store.trust(host: "example.com", port: 22, keyBlob: Fixtures.publicKeyBlob) == .unknown)
    }

    @Test("A matching key is trusted, in both plain and hashed files", arguments: [false, true])
    func recognisesKnownKey(hashed: Bool) async throws {
        let (store, _) = try makeStore(contents: hashed ? Fixtures.hashedKnownHosts : Fixtures.plainKnownHosts)

        #expect(try await store.trust(host: "example.com", port: 22, keyBlob: Fixtures.publicKeyBlob) == .trusted)
        #expect(try await store.trust(host: "localhost", port: 2222, keyBlob: Fixtures.publicKeyBlob) == .trusted)
    }

    @Test("A host with no entry is unknown")
    func unknownHost() async throws {
        let (store, _) = try makeStore(contents: Fixtures.plainKnownHosts)
        #expect(try await store.trust(host: "new.example.org", port: 22, keyBlob: Fixtures.publicKeyBlob) == .unknown)
    }

    @Test("A different key of the same algorithm is a mismatch, not a new host")
    func detectsChangedKey() async throws {
        // The security-critical distinction: this is the case that may be an attack, and it must be
        // reported differently from first contact.
        let (store, _) = try makeStore(contents: Fixtures.plainKnownHosts)

        let trust = try await store.trust(host: "example.com", port: 22, keyBlob: Fixtures.otherPublicKeyBlob)
        #expect(trust == .mismatch(storedFingerprint: Fixtures.expectedFingerprint))
    }

    @Test("A revoked key is refused outright")
    func revokedKeyRefused() async throws {
        let contents = "@revoked example.com ssh-ed25519 \(Fixtures.publicKeyBase64)"
        let (store, _) = try makeStore(contents: contents)

        #expect(try await store.trust(host: "example.com", port: 22, keyBlob: Fixtures.publicKeyBlob) == .revoked)
    }

    @Test("Revocation wins even when the same key is also listed as valid")
    func revocationTakesPrecedence() async throws {
        let contents = """
            example.com ssh-ed25519 \(Fixtures.publicKeyBase64)
            @revoked example.com ssh-ed25519 \(Fixtures.publicKeyBase64)
            """
        let (store, _) = try makeStore(contents: contents)

        #expect(try await store.trust(host: "example.com", port: 22, keyBlob: Fixtures.publicKeyBlob) == .revoked)
    }

    @Test("Appending preserves the existing file byte for byte")
    func appendPreservesFile() async throws {
        let original = Fixtures.plainKnownHosts + "\n"
        let (store, url) = try makeStore(contents: original)

        try await store.append(host: "new.example.org", port: 2200, keyBlob: Fixtures.publicKeyBlob)

        let updated = try String(contentsOf: url, encoding: .utf8)
        #expect(updated.hasPrefix(original))                       // nothing before was disturbed
        #expect(updated.hasSuffix("\n"))
        #expect(updated.contains("[new.example.org]:2200 ssh-ed25519 \(Fixtures.publicKeyBase64)"))
    }

    @Test("An appended key is trusted on the next connection")
    func appendThenTrust() async throws {
        let (store, _) = try makeStore()

        #expect(try await store.trust(host: "fresh.test", port: 22, keyBlob: Fixtures.publicKeyBlob) == .unknown)
        try await store.append(host: "fresh.test", port: 22, keyBlob: Fixtures.publicKeyBlob)
        #expect(try await store.trust(host: "fresh.test", port: 22, keyBlob: Fixtures.publicKeyBlob) == .trusted)
    }

    @Test("Appending creates the file when none exists")
    func appendCreatesFile() async throws {
        let (store, url) = try makeStore()
        try await store.append(host: "fresh.test", port: 22, keyBlob: Fixtures.publicKeyBlob)

        #expect(FileManager.default.fileExists(atPath: url.path))
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written == "fresh.test ssh-ed25519 \(Fixtures.publicKeyBase64)\n")
    }
}
