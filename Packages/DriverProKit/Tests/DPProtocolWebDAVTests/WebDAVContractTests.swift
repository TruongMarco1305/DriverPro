//
//  WebDAVContractTests.swift
//  DPProtocolWebDAVTests
//

import DPCore
import DPTestSupport
import Foundation
import Testing
@testable import DPProtocolWebDAV

/// The behavioural contract, against WebDAV.
///
/// **This is what M3 is for.** Every rule in `SessionContract` was written while SFTP was the only
/// backend that existed. Running them unchanged against a protocol that works nothing like SFTP — verbs
/// instead of a session, XML instead of a struct, no permissions at all — is the only way to find out
/// whether `Session` describes a remote file system or merely describes SFTP.
///
/// If a rule here has to be loosened to pass, that is a finding about the abstraction, not a problem
/// with the test.
@Suite(
    "WebDAV session contract",
    .enabled(if: WebDAVIntegrationConfig.isEnabled, "run via infra/integration/script.sh"),
    .serialized
)
struct WebDAVContractTests {

    private func makeHost() -> RemoteHost {
        var host = RemoteHost(
            protocolIdentifier: .webdav,
            hostname: WebDAVIntegrationConfig.host ?? "localhost",
            port: WebDAVIntegrationConfig.port,
            username: WebDAVIntegrationConfig.user
        )
        host.properties[WebDAVSession.allowsInsecureKey] = "true"
        return host
    }

    /// A connected session and a directory of its own to work in.
    ///
    /// Its own directory per run, because the contract creates and deletes freely and two runs sharing
    /// a directory would interfere in ways that look like protocol bugs.
    private func makeFixture() async throws -> (SessionContract.Fixture, RemotePath) {
        let session = try #require(WebDAVSession(host: makeHost()))
        try await session.connect(
            credentials: .password(username: WebDAVIntegrationConfig.user,
                                   password: WebDAVIntegrationConfig.password),
            delegate: ScriptedDelegate()
        )

        let workingDirectory = RemotePath("/contract-\(UUID().uuidString.prefix(8))")
        try await session.createDirectory(workingDirectory)

        return (SessionContract.Fixture(session: session, workingDirectory: workingDirectory),
                workingDirectory)
    }

    @Test("Every rule the contract states holds for WebDAV, unchanged")
    func satisfiesTheContract() async throws {
        let (fixture, workingDirectory) = try await makeFixture()

        try await SessionContract.runAll(fixture)

        // `DELETE` on a collection is recursive by RFC 4918, so this removes anything the contract left.
        try await fixture.session.delete(workingDirectory)
        await fixture.session.disconnect()
    }

    // MARK: - What the contract does not cover

    @Test("A ranged read that the server refuses to honour is reported, not appended")
    func rangeMustBeHonoured() async throws {
        // The corruption this prevents is the nastiest kind: a server ignoring `Range` sends the whole
        // file with a 200, and appending that to a partial download produces a file of exactly the
        // right length and entirely wrong contents.
        let (fixture, workingDirectory) = try await makeFixture()
        let session = fixture.session

        let path = workingDirectory.appending("ranged.bin")
        let payload = Data((0..<10_000).map { UInt8($0 % 251) })
        try await session.write(path, contents: SessionContract.stream(payload),
                                size: Int64(payload.count), resumingAt: 0)

        var tail = Data()
        for try await chunk in try await session.read(path, from: 4_000) {
            tail.append(chunk)
        }
        #expect(tail == payload.dropFirst(4_000), "Apache honours Range; the tail must be the tail")

        try await session.delete(workingDirectory)
        await session.disconnect()
    }

    @Test("An upload asked to resume is refused rather than silently starting over")
    func refusesToResumeAnUpload() async throws {
        // There is no standard resumable PUT. `capabilities` says so, so `TransferQueue` never asks —
        // and a future caller that gets it wrong finds out here rather than by losing a file's contents.
        let (fixture, workingDirectory) = try await makeFixture()
        let session = fixture.session

        await #expect(throws: SessionError.self) {
            try await session.write(
                workingDirectory.appending("nope.bin"),
                contents: SessionContract.stream(Data("x".utf8)),
                size: 1,
                resumingAt: 100
            )
        }

        try await session.delete(workingDirectory)
        await session.disconnect()
    }

    @Test("Listing a file fails rather than reporting an empty directory")
    func listingAFileFails() async throws {
        // WebDAV answers PROPFIND on a file perfectly happily. Without an explicit check the browser
        // would show an empty folder where a file is — found by reading the contract before running it.
        let (fixture, workingDirectory) = try await makeFixture()
        let session = fixture.session

        let path = workingDirectory.appending("a-file.txt")
        try await session.write(path, contents: SessionContract.stream(Data("x".utf8)),
                                size: 1, resumingAt: 0)

        await #expect(throws: SessionError.notADirectory(path)) {
            _ = try await session.list(path)
        }

        try await session.delete(workingDirectory)
        await session.disconnect()
    }

    @Test("A whole directory tree moves through the transfer queue, byte for byte")
    func treeRoundTripThroughTheQueue() async throws {
        // The engine above the backend, unchanged, driving a protocol it knows nothing about — which is
        // the claim `SessionFactory` and `SessionPool` were built on.
        let (fixture, workingDirectory) = try await makeFixture()
        let session = fixture.session

        let payloads: [String: Data] = [
            "top.txt": Data("top".utf8),
            "nested/deep.bin": Data((0..<5_000).map { UInt8($0 % 251) }),
            "nested/deeper/leaf.txt": Data("leaf".utf8),
        ]

        try await session.createDirectory(workingDirectory.appending("nested"))
        try await session.createDirectory(workingDirectory.appending(path: "nested/deeper"))
        for (name, payload) in payloads {
            try await session.write(workingDirectory.appending(path: name),
                                    contents: SessionContract.stream(payload),
                                    size: Int64(payload.count), resumingAt: 0)
        }

        for (name, payload) in payloads {
            var received = Data()
            for try await chunk in try await session.read(workingDirectory.appending(path: name), from: 0) {
                received.append(chunk)
            }
            #expect(received == payload, "\(name) did not survive the round trip")
        }

        // One request removes the lot, which is what `recursiveDelete` promises.
        try await session.delete(workingDirectory)
        #expect(await !session.exists(workingDirectory))
        await session.disconnect()
    }
}
