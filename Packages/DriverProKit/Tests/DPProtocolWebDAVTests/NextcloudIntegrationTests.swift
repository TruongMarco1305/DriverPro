//
//  NextcloudIntegrationTests.swift
//  DPProtocolWebDAVTests
//

import DPCore
import DPTestSupport
import Foundation
import Testing
@testable import DPProtocolWebDAV

/// Where the Nextcloud instance is, when there is one.
enum NextcloudConfig {
    static let host = ProcessInfo.processInfo.environment["NEXTCLOUD_HOST"]
    static let port = Int(ProcessInfo.processInfo.environment["NEXTCLOUD_PORT"] ?? "") ?? 8082
    static let user = ProcessInfo.processInfo.environment["NEXTCLOUD_USER"] ?? "duck"
    static let password = ProcessInfo.processInfo.environment["NEXTCLOUD_PASSWORD"] ?? "nextcloudpassword"
    static let basePath = ProcessInfo.processInfo.environment["NEXTCLOUD_BASE_PATH"]
        ?? "/remote.php/dav/files/duck"

    static var isEnabled: Bool { host != nil }
}

/// The same backend, against a real product.
///
/// **This is the test M3 was built to run.** Apache's `mod_dav` is the reference implementation;
/// Nextcloud is what people actually have. The claim being checked is narrow and falsifiable: that the
/// difference between them is *configuration* — a DAV root in `RemoteHost.properties` — and not a branch
/// anywhere in the code.
///
/// If anything here needs `if host.isNextcloud`, the claim was wrong and belongs in an ADR rather than
/// in a condition.
@Suite(
    "Nextcloud",
    .enabled(if: NextcloudConfig.isEnabled, "run via infra/integration/script.sh"),
    .serialized
)
struct NextcloudIntegrationTests {

    private func makeHost() -> RemoteHost {
        var host = RemoteHost(
            protocolIdentifier: .webdav,
            hostname: NextcloudConfig.host ?? "localhost",
            port: NextcloudConfig.port,
            username: NextcloudConfig.user
        )
        // The only two things that differ from the plain server. One is the DAV root; the other is that
        // the test container speaks HTTP, which a real deployment would not.
        host.properties[RemoteHost.webdavBasePathKey] = NextcloudConfig.basePath
        host.properties[WebDAVSession.allowsInsecureKey] = "true"
        return host
    }

    @Test("Connecting without the DAV root says what is wrong, and names the field that fixes it")
    func missingDavRootIsExplained() async throws {
        // Reported from the app: connecting to a local Nextcloud answered "/ already exists."
        //
        // Nextcloud's web front end answers 405 to a PROPFIND, and 405 was mapped to `alreadyExists`
        // whatever the verb — so leaving the WebDAV Path empty produced a message that was meaningless
        // and, worse, described a state that was not true. The field is easy to leave blank because its
        // placeholder shows the shape of the answer and reads like a value already filled in.
        var host = makeHost()
        host.properties.removeValue(forKey: RemoteHost.webdavBasePathKey)

        let session = try #require(WebDAVSession(host: host))
        var caught: (any Error)?
        do {
            try await session.connect(
                credentials: .password(username: NextcloudConfig.user,
                                       password: NextcloudConfig.password),
                delegate: ScriptedDelegate()
            )
        } catch {
            caught = error
        }

        guard case .protocolViolation(let reason)? = caught as? SessionError else {
            Issue.record("expected a protocol violation naming the DAV root, got \(caught as Any)")
            return
        }
        #expect(reason.contains("WebDAV Path"))
        #expect(reason.contains("/remote.php/dav/files/"), "the shape of the answer, not just a scolding")
        // Three fields combine into one URL, so naming it is what turns "check the path" from advice
        // into something the user can compare against what they meant to type.
        #expect(reason.contains("Tried:"), "the address actually asked for")
        #expect(reason.contains("\(NextcloudConfig.port)"), "including the port, which is often the wrong one")
    }

    private func connected() async throws -> WebDAVSession {
        let session = try #require(WebDAVSession(host: makeHost()))
        try await session.connect(
            credentials: .password(username: NextcloudConfig.user, password: NextcloudConfig.password),
            delegate: ScriptedDelegate()
        )
        return session
    }

    private func makeFixture() async throws -> (SessionContract.Fixture, WebDAVSession, RemotePath) {
        let session = try await connected()
        let workingDirectory = RemotePath("/contract-\(UUID().uuidString.prefix(8))")
        try await session.createDirectory(workingDirectory)

        return (SessionContract.Fixture(session: session, workingDirectory: workingDirectory),
                session, workingDirectory)
    }

    @Test("Every rule the contract states holds for Nextcloud, unchanged")
    func satisfiesTheContract() async throws {
        // Same suite, same backend, same code path as Apache. Only the base path property differs.
        let (fixture, session, workingDirectory) = try await makeFixture()

        try await SessionContract.runAll(fixture)

        try await session.delete(workingDirectory)
        await session.disconnect()
    }

    @Test("The DAV root is a property, and paths above this layer never see it")
    func basePathIsConfiguration() async throws {
        // The claim, stated as a test: what the browser calls `/Documents` is
        // `/remote.php/dav/files/duck/Documents` on the wire, and nothing above `WebDAVPaths` knows.
        let session = try await connected()
        defer { Task { await session.disconnect() } }

        let items = try await session.list(.root)

        #expect(!items.isEmpty, "a fresh Nextcloud account has example files in it")
        #expect(items.allSatisfy { !$0.path.pathString.contains("remote.php") },
                "the prefix belongs to the transport, not to the paths anyone else handles")
        #expect(items.contains { $0.isDirectory }, "and folders come back as folders")
    }

    @Test("Nextcloud's own namespaces do not confuse the parser")
    func vendorNamespacesAreIgnored() async throws {
        // Every response carries `oc:` and `nc:` alongside `d:`. A parser matching element names by
        // prefix would read these listings as empty — which is why it reads local names instead.
        let session = try await connected()
        defer { Task { await session.disconnect() } }

        let items = try await session.list(.root)
        #expect(items.allSatisfy { !$0.name.isEmpty })
        #expect(items.contains { $0.modifiedAt != nil }, "dates parsed out of a document full of vendor tags")
    }

    @Test("An awkward name survives Nextcloud's encoding as well as ours")
    func awkwardNamesRoundTrip() async throws {
        // HTTP makes this sharper than SFTP, and a vendor's encoding is its own decision — so it is
        // checked against the server that will actually store the file.
        let (fixture, session, workingDirectory) = try await makeFixture()

        for name in ["a file.txt", "hash#1.txt", "100%.txt", "日本語.txt"] {
            let path = workingDirectory.appending(name)
            let payload = Data("contents of \(name)".utf8)

            try await session.write(path, contents: SessionContract.stream(payload),
                                    size: Int64(payload.count), resumingAt: 0)

            var received = Data()
            for try await chunk in try await session.read(path, from: 0) { received.append(chunk) }
            #expect(received == payload, "“\(name)” did not survive")
        }

        // And they come back from a listing under the names they were given.
        let listed = Set(try await session.list(workingDirectory).map(\.name))
        #expect(listed == ["a file.txt", "hash#1.txt", "100%.txt", "日本語.txt"])

        try await session.delete(workingDirectory)
        await session.disconnect()
        _ = fixture
    }

    @Test("A wrong password is refused as such")
    func rejectsWrongPassword() async throws {
        // Worth checking against the real product: Nextcloud answers a bad login with a 401 carrying its
        // own HTML body, and the message the user sees should still be about the password.
        let session = try #require(WebDAVSession(host: makeHost()))

        await #expect(throws: SessionError.self) {
            try await session.connect(
                credentials: .password(username: NextcloudConfig.user, password: "wrong"),
                delegate: ScriptedDelegate()
            )
        }
    }
}
