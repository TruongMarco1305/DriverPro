//
//  S3ServerFixture.swift
//  DPProtocolS3Tests
//

import DPCore
import DPTestSupport
import Foundation
import SotoS3
import Testing
@testable import DPProtocolS3

/// One S3-compatible server the tests can be pointed at.
///
/// Two implementations run in Docker — MinIO and LocalStack — and the same checks run against both,
/// because one server is not evidence about another. M3 learned that expensively: the session contract
/// passed against Apache's `mod_dav` and failed against Nextcloud over a caching behaviour neither
/// documents.
///
/// This is deliberately shaped as the thing slice 4d needs. There, the same fixture is filled from
/// environment variables naming a *real* provider — AWS, GCS, R2, B2, Spaces — and the conformance
/// matrix is this type plus a list of endpoints.
struct S3ServerFixture: Sendable {

    /// Where the server is. `nil` means it was not started, and the suite skips.
    let host: String?
    /// The port it answers on.
    let port: Int
    /// The access key id, which is also ``RemoteHost/username``.
    let accessKey: String
    /// The secret access key.
    let secretKey: String
    /// The region to sign for.
    let region: String
    /// The bucket the tests work in.
    let bucket: String

    /// Whether there is a server to talk to.
    var isEnabled: Bool { host != nil }

    /// The second bucket, so that listing the root proves more than a hard-coded single entry would.
    var secondBucket: String { "\(bucket)-second" }

    // MARK: - The servers

    /// MinIO, whose buckets are pre-created as directories in its data volume.
    static let minio = S3ServerFixture(
        host: ProcessInfo.processInfo.environment["S3_HOST"],
        port: Int(ProcessInfo.processInfo.environment["S3_PORT"] ?? "") ?? 9000,
        accessKey: ProcessInfo.processInfo.environment["S3_ACCESS_KEY"] ?? "driverpro",
        secretKey: ProcessInfo.processInfo.environment["S3_SECRET_KEY"] ?? "driverpropassword",
        region: ProcessInfo.processInfo.environment["S3_REGION"] ?? "us-east-1",
        bucket: ProcessInfo.processInfo.environment["S3_BUCKET"] ?? "integration"
    )

    /// LocalStack, which starts empty — see ``ensureBuckets()``.
    static let localStack = S3ServerFixture(
        host: ProcessInfo.processInfo.environment["LOCALSTACK_HOST"],
        port: Int(ProcessInfo.processInfo.environment["LOCALSTACK_PORT"] ?? "") ?? 4566,
        accessKey: ProcessInfo.processInfo.environment["LOCALSTACK_ACCESS_KEY"] ?? "test",
        secretKey: ProcessInfo.processInfo.environment["LOCALSTACK_SECRET_KEY"] ?? "test",
        region: ProcessInfo.processInfo.environment["LOCALSTACK_REGION"] ?? "us-east-1",
        bucket: ProcessInfo.processInfo.environment["LOCALSTACK_BUCKET"] ?? "integration"
    )

    // MARK: - Connecting

    /// The bookmark that reaches this server.
    func makeHost() -> RemoteHost {
        var remote = RemoteHost(
            protocolIdentifier: .s3,
            hostname: host ?? "localhost",
            port: port,
            username: accessKey
        )
        // Both containers serve plain HTTP, exactly as the WebDAV one does and for the same reason: TLS
        // is a separate question from the protocol.
        remote.properties[S3Client.allowsInsecureKey] = "true"
        remote.properties[S3Client.regionKey] = region
        return remote
    }

    /// The credentials that server accepts.
    func makeCredentials() -> Credentials {
        .password(username: accessKey, password: secretKey)
    }

    /// Runs `body` with a connected session, and disconnects whatever happens.
    ///
    /// **Awaited rather than deferred.** `defer { Task { await session.disconnect() } }` reads like
    /// cleanup and is not: a detached task is no part of the test's lifetime, so it can run during the
    /// *next* test, or after the suite has finished. `.serialized` orders the tests, not the strays they
    /// leave behind. Here both the success and the failure path disconnect before returning.
    ///
    /// - Parameter body: What to do with the session.
    /// - Returns: Whatever `body` returned.
    func withSession<T>(_ body: (S3Session) async throws -> T) async throws -> T {
        let session = S3Session(host: makeHost())
        try await session.connect(credentials: makeCredentials(), delegate: ScriptedDelegate())
        do {
            let value = try await body(session)
            await session.disconnect()
            return value
        } catch {
            await session.disconnect()
            throw error
        }
    }

    /// Runs `body` with the given keys in place, and removes them whatever happens.
    ///
    /// - Parameters:
    ///   - keys: Object keys to create, each holding the five bytes `hello`.
    ///   - body: What to do while they exist.
    /// - Returns: Whatever `body` returned.
    func withSeeded<T>(_ keys: [String], _ body: (S3Session) async throws -> T) async throws -> T {
        try await withSession { session in
            try await seed(keys)
            do {
                let value = try await body(session)
                try await unseed(keys)
                return value
            } catch {
                // Best effort: the test is already failing, and a cleanup failure on top of it would
                // replace the useful error with a useless one.
                try? await unseed(keys)
                throw error
            }
        }
    }

    // MARK: - Arranging objects

    /// Creates the buckets the tests expect, ignoring the ones already there.
    ///
    /// MinIO gets its buckets as directories in its data volume; LocalStack starts with none. Calling
    /// this is harmless against either, which is what lets one fixture serve both.
    func ensureBuckets() async throws {
        try await withClient { client in
            for name in [bucket, secondBucket] {
                do {
                    _ = try await client.s3.createBucket(.init(bucket: name))
                } catch {
                    // Already ours is the expected answer on every run after the first.
                    guard case .alreadyExists = S3ErrorMapping.map(error, path: RemotePath("/\(name)"))
                    else { throw error }
                }
            }
        }
    }

    /// Puts small objects in place, using Soto directly.
    ///
    /// Slice 4a has no `write`, so the fixture cannot arrange what it needs through the `Session` API.
    /// Reaching past the type under test is the right trade here: it keeps these tests about listing.
    func seed(_ keys: [String]) async throws {
        try await withClient { client in
            try await inParallel(keys) { key in
                _ = try await client.s3.putObject(
                    .init(body: .init(string: "hello"), bucket: bucket, key: key)
                )
            }
        }
    }

    /// Removes what ``seed(_:)`` put in place.
    func unseed(_ keys: [String]) async throws {
        try await withClient { client in
            try await inParallel(keys) { key in
                _ = try await client.s3.deleteObject(.init(bucket: bucket, key: key))
            }
        }
    }

    // MARK: - Helpers

    /// Runs `body` with a raw Soto client, shutting it down before returning.
    ///
    /// `AWSClient.deinit` asserts that shutdown happened first, so this is awaited for the same reason
    /// ``withSession(_:)`` is — a detached shutdown is a trap waiting for a debug build.
    private func withClient<T>(_ body: (S3Client) async throws -> T) async throws -> T {
        let client = S3Client(host: makeHost(), accessKeyID: accessKey, secretAccessKey: secretKey)
        do {
            let value = try await body(client)
            await client.shutdown()
            return value
        } catch {
            await client.shutdown()
            throw error
        }
    }

    /// Runs `work` over every key, a bounded number at a time.
    ///
    /// The bound is the point. A `TaskGroup` given 1,100 uploads at once starts 1,100 of them, and
    /// AsyncHTTPClient's connection pool answers with an error about the client rather than the server,
    /// in a test that is about neither. The sliding-window shape is the one written up in
    /// `docs/swift-notes.md` §20.
    private func inParallel(
        _ keys: [String],
        _ work: @escaping @Sendable (String) async throws -> Void
    ) async throws {
        let limit = 16
        try await withThrowingTaskGroup(of: Void.self) { group in
            var pending = keys.makeIterator()
            for _ in 0..<limit {
                guard let key = pending.next() else { break }
                group.addTask { try await work(key) }
            }
            while try await group.next() != nil {
                guard let key = pending.next() else { continue }
                group.addTask { try await work(key) }
            }
        }
    }
}
