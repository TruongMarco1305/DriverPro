//
//  WebDAVIntegrationTests.swift
//  DPProtocolWebDAVTests
//

import DPCore
import DPTestSupport
import Foundation
import Testing
@testable import DPProtocolWebDAV

/// Where the WebDAV server is, when there is one.
///
/// Every value comes from `infra/integration/.env`, exported by `script.sh`. Unset means no server, and
/// the suite skips — the default `swift test` stays hermetic and offline.
enum WebDAVIntegrationConfig {

    static let host = ProcessInfo.processInfo.environment["WEBDAV_HOST"]
    static let port = Int(ProcessInfo.processInfo.environment["WEBDAV_PORT"] ?? "") ?? 8081
    static let user = ProcessInfo.processInfo.environment["WEBDAV_USER"] ?? "duck"
    static let password = ProcessInfo.processInfo.environment["WEBDAV_PASSWORD"] ?? "davpassword"

    static var isEnabled: Bool { host != nil }
}

/// The WebDAV backend against a real server.
///
/// A stub proves the requests are shaped right; only a server proves they are *understood*. Apache's
/// `mod_dav` is the reference implementation of the parts every server agrees on, which is why slice 3a
/// builds against it rather than Nextcloud.
@Suite(
    "WebDAV integration",
    .enabled(if: WebDAVIntegrationConfig.isEnabled, "run via infra/integration/script.sh"),
    .serialized
)
struct WebDAVIntegrationTests {

    private func makeHost() -> RemoteHost {
        var host = RemoteHost(
            protocolIdentifier: .webdav,
            hostname: WebDAVIntegrationConfig.host ?? "localhost",
            port: WebDAVIntegrationConfig.port,
            username: WebDAVIntegrationConfig.user
        )
        // The container serves plain HTTP. TLS, and the certificate prompt, arrive in slice 3c.
        host.properties[WebDAVSession.allowsInsecureKey] = "true"
        return host
    }

    private func connected() async throws -> WebDAVSession {
        let session = try #require(WebDAVSession(host: makeHost()))
        try await session.connect(
            credentials: .password(username: WebDAVIntegrationConfig.user,
                                   password: WebDAVIntegrationConfig.password),
            delegate: ScriptedDelegate()
        )
        return session
    }

    @Test("Connecting to a real server succeeds, and a wrong password does not")
    func connects() async throws {
        let session = try await connected()
        #expect(await session.isConnected)
        await session.disconnect()

        let refused = try #require(WebDAVSession(host: makeHost()))
        await #expect(throws: SessionError.self) {
            try await refused.connect(
                credentials: .password(username: WebDAVIntegrationConfig.user, password: "wrong"),
                delegate: ScriptedDelegate()
            )
        }
    }

    @Test("The root lists without error")
    func listsRoot() async throws {
        // Apache answers a real 207 here, with its own namespace prefixes and its own idea of which
        // properties to report absent. Everything the parser was written against, from the source.
        let session = try await connected()
        defer { Task { await session.disconnect() } }

        let items = try await session.list(.root)
        #expect(!items.contains { $0.path == .root }, "a directory must not contain itself")
    }

    @Test("A missing path is reported as not found, by name")
    func missingPath() async throws {
        let session = try await connected()
        defer { Task { await session.disconnect() } }

        let missing = RemotePath("/definitely-not-here-\(UUID().uuidString)")
        await #expect(throws: SessionError.notFound(missing)) {
            _ = try await session.stat(missing)
        }
        #expect(await !session.exists(missing))
    }

    @Test("What the server cannot do is refused, not attempted")
    func refusesWhatWebDAVLacks() async throws {
        // The capability system's first real outing: these are absent by protocol, and the failure is a
        // clean refusal naming what is missing rather than an HTTP error nobody can act on.
        let session = try await connected()
        defer { Task { await session.disconnect() } }

        await #expect(throws: SessionError.self) {
            try await session.setPermissions(POSIXPermissions(rawValue: 0o644), at: .root)
        }
        await #expect(throws: SessionError.self) {
            try await session.setModificationDate(Date(), at: .root)
        }
    }
}
