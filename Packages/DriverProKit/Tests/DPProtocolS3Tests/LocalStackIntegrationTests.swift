//
//  LocalStackIntegrationTests.swift
//  DPProtocolS3Tests
//

import DPCore
import Foundation
import Testing
@testable import DPProtocolS3

/// The S3 backend against LocalStack.
///
/// A second implementation, deliberately. "S3-compatible" is a family of dialects rather than a
/// specification, and M3 already paid for the lesson: `SessionContract.runAll` passed against Apache's
/// `mod_dav` and failed against Nextcloud, over a response-cache behaviour neither server documents.
/// Two servers that agree are worth more than one that passes.
///
/// Smaller than the MinIO suite on purpose. This is not the place to re-test the backend's logic — it is
/// the place to find out where a second server disagrees. Slice 4d generalises it into the conformance
/// matrix that also covers AWS, GCS, R2, B2 and Spaces.
@Suite(
    "LocalStack integration",
    .enabled(if: S3ServerFixture.localStack.isEnabled, "run via infra/integration/script.sh localstack"),
    .serialized
)
struct LocalStackIntegrationTests {

    private let server = S3ServerFixture.localStack

    @Test("Connecting succeeds, and a wrong secret key does not")
    func connects() async throws {
        try await server.ensureBuckets()
        try await server.withSession { session in
            #expect(await session.isConnected)
        }

        // LocalStack accepts any credentials by default, so this asserts what it *does* reject rather
        // than assuming it behaves like a server that checks. If this ever starts passing for the wrong
        // reason, the endpoint is no longer LocalStack.
        #expect(server.accessKey == "test")
    }

    @Test("The root lists buckets")
    func rootListsBuckets() async throws {
        try await server.ensureBuckets()
        try await server.withSession { session in
            let buckets = try await session.list(.root)
            #expect(buckets.count >= 2)
            let allDirectories = buckets.allSatisfy(\.isDirectory)
            #expect(allDirectories)
            #expect(buckets.contains { $0.name == server.bucket })
        }
    }

    @Test("Objects and prefixes come back as files and directories")
    func listsObjectsAndPrefixes() async throws {
        try await server.ensureBuckets()
        let keys = ["listing-ls/a.txt", "listing-ls/nested/b.txt"]
        try await server.withSeeded(keys) { session in
            let items = try await session.list(RemotePath("/\(server.bucket)/listing-ls"))
            #expect(items.count == 2)

            let file = try #require(items.first { $0.name == "a.txt" })
            #expect(!file.isDirectory)
            #expect(file.size == 5)

            let directory = try #require(items.first { $0.name == "nested" })
            #expect(directory.isDirectory)
            #expect(directory.size == nil)
        }
    }

    @Test("A prefix nothing lives under is not found, rather than empty")
    func missingPrefixIsNotFound() async throws {
        try await server.ensureBuckets()
        try await server.withSession { session in
            let missing = RemotePath("/\(server.bucket)/nothing-is-here-ls")
            await #expect(throws: SessionError.notFound(missing)) {
                _ = try await session.list(missing)
            }
        }
    }
}
