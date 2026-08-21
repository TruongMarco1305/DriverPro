//
//  TrustedCertificateStoreTests.swift
//  DPCredentialsTests
//

import DPCore
import Foundation
import Testing
@testable import DPCredentials

@Suite("TrustedCertificateStore")
struct TrustedCertificateStoreTests {

    /// A store over a throwaway file, so nothing touches the real one.
    private func makeStore() -> (TrustedCertificateStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-certs-\(UUID().uuidString)/trusted.json")
        return (TrustedCertificateStore(fileURL: url), url)
    }

    private func makeCertificate(
        hostname: String = "cloud.example.com",
        port: Int = 443,
        fingerprint: String = "SHA256:aaa"
    ) -> TrustedCertificate {
        TrustedCertificate(hostname: hostname, port: port, fingerprint: fingerprint,
                           subject: "CN=cloud.example.com", issuer: "CN=cloud.example.com")
    }

    @Test("A server nothing is known about is unknown")
    func startsUnknown() async {
        let (store, _) = makeStore()
        #expect(await store.trust(hostname: "cloud.example.com", port: 443, fingerprint: "SHA256:aaa")
                == .unknown)
    }

    @Test("An accepted certificate is trusted next time")
    func acceptedIsTrusted() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.store(makeCertificate())

        #expect(await store.trust(hostname: "cloud.example.com", port: 443, fingerprint: "SHA256:aaa")
                == .trusted)
    }

    @Test("The host name is matched without regard to case")
    func hostnameIsCaseInsensitive() async throws {
        // A bookmark typed as `Cloud.Example.com` and one typed in lower case are the same server, and
        // asking twice about the same certificate would be a bug the user reads as forgetfulness.
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.store(makeCertificate(hostname: "Cloud.Example.com"))

        #expect(await store.trust(hostname: "cloud.example.com", port: 443, fingerprint: "SHA256:aaa")
                == .trusted)
    }

    @Test("A different certificate for the same server is a mismatch, carrying the stored one")
    func differentCertificateIsMismatch() async throws {
        // The serious case. The stored fingerprint comes back so the sheet can show both, because "this
        // changed" is only actionable if you can see what it changed from.
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.store(makeCertificate(fingerprint: "SHA256:aaa"))

        #expect(await store.trust(hostname: "cloud.example.com", port: 443, fingerprint: "SHA256:bbb")
                == .mismatch(storedFingerprint: "SHA256:aaa"))
    }

    @Test("A different port is a different server")
    func portIsPartOfIdentity() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.store(makeCertificate(port: 443))

        #expect(await store.trust(hostname: "cloud.example.com", port: 8443, fingerprint: "SHA256:aaa")
                == .unknown)
    }

    @Test("Accepting a renewal replaces the old record rather than adding to it")
    func renewalReplaces() async throws {
        // Keeping both would mean an impersonator whose certificate was once accepted stays trusted
        // forever. The user has just been shown both and chosen.
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.store(makeCertificate(fingerprint: "SHA256:old"))
        try await store.store(makeCertificate(fingerprint: "SHA256:new"))

        #expect(await store.entries().count == 1)
        #expect(await store.trust(hostname: "cloud.example.com", port: 443, fingerprint: "SHA256:new")
                == .trusted)
        #expect(await store.trust(hostname: "cloud.example.com", port: 443, fingerprint: "SHA256:old")
                == .mismatch(storedFingerprint: "SHA256:new"), "the old one is no longer trusted")
    }

    @Test("Records survive being written and read back")
    func survivesAReload() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.store(makeCertificate())

        // A second store over the same file is what the next launch looks like.
        let reopened = TrustedCertificateStore(fileURL: url)
        #expect(await reopened.trust(hostname: "cloud.example.com", port: 443,
                                     fingerprint: "SHA256:aaa") == .trusted)
    }

    @Test("Forgetting a server asks again next time")
    func forgetting() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.store(makeCertificate())
        try await store.forget(hostname: "cloud.example.com", port: 443)

        #expect(await store.trust(hostname: "cloud.example.com", port: 443, fingerprint: "SHA256:aaa")
                == .unknown)
    }

    @Test("A file that cannot be read leaves the app able to connect")
    func corruptFileIsNotFatal() async throws {
        // An unreadable trust file must not stop anyone reaching a server the system already trusts —
        // it should only mean nothing is remembered.
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: url)

        #expect(await store.entries().isEmpty)
        #expect(await store.trust(hostname: "cloud.example.com", port: 443,
                                  fingerprint: "SHA256:aaa") == .unknown)

        // And it recovers: writing replaces the rubbish rather than failing forever.
        try await store.store(makeCertificate())
        #expect(await store.entries().count == 1)
    }

    @Test("The file is readable by a person")
    func fileIsReadable() async throws {
        // The reason this is a file rather than a database: when trust goes wrong, the useful thing
        // someone can do is open it, look, and delete a line.
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.store(makeCertificate())
        let written = try String(contentsOf: url, encoding: .utf8)

        #expect(written.contains("cloud.example.com"))
        #expect(written.contains("SHA256:aaa"))
        #expect(written.contains("acceptedAt"))
        #expect(written.contains("\n"), "pretty-printed, not one long line")
    }
}
