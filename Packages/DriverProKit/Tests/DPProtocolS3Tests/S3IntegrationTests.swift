//
//  S3IntegrationTests.swift
//  DPProtocolS3Tests
//

import DPCore
import DPTestSupport
import Foundation
import Testing
@testable import DPProtocolS3

/// The S3 backend against MinIO.
///
/// MinIO rather than Amazon because it is the same API on a laptop: no account, no bill, and no network
/// between a failing test and the reason it failed. LocalStack runs the same checks in a sibling suite;
/// the five real providers, which cannot run in Docker, are slice 4d's conformance matrix.
@Suite(
    "S3 integration",
    .enabled(if: S3ServerFixture.minio.isEnabled, "run via infra/integration/script.sh s3"),
    .serialized
)
struct S3IntegrationTests {

    private let server = S3ServerFixture.minio

    // MARK: - Connecting

    @Test("Connecting succeeds, and a wrong secret key does not")
    func connects() async throws {
        try await server.withSession { session in
            #expect(await session.isConnected)
        }

        let refused = S3Session(host: server.makeHost())
        await #expect(throws: SessionError.self) {
            try await refused.connect(
                credentials: .password(username: server.accessKey, password: "wrong"),
                delegate: ScriptedDelegate()
            )
        }
    }

    @Test("A session opened and closed repeatedly neither traps nor leaks")
    func lifetime() async throws {
        // `AWSClient.deinit` asserts that shutdown happened first, so a debug build turns a missed
        // `disconnect` into a trap. This is the test that would catch it — and it is why `connect`
        // shuts the client down on a failed probe rather than letting it fall out of scope.
        for _ in 0..<20 {
            try await server.withSession { _ in }
        }
    }

    // MARK: - The root

    @Test("The root lists buckets, and there is more than one")
    func rootListsBuckets() async throws {
        try await server.withSession { session in
            let buckets = try await session.list(.root)
            // Two seeded buckets, because one proves nothing: a listing that hard-coded a single entry
            // would look identical.
            #expect(buckets.count >= 2)
            // Bound first rather than inlined: `#expect` expands `allSatisfy` into a call it must treat
            // as throwing, which the macro then refuses to build without a `try`.
            let allDirectories = buckets.allSatisfy(\.isDirectory)
            // A bucket is one component deep, which is what makes it the first component of every key.
            let allTopLevel = buckets.allSatisfy { $0.path.components.count == 1 }
            #expect(allDirectories)
            #expect(allTopLevel)
            #expect(buckets.contains { $0.name == server.bucket })
        }
    }

    @Test("A bucket describes itself, and a bucket that is not there is not found")
    func statBucket() async throws {
        try await server.withSession { session in
            let bucket = try await session.stat(RemotePath("/\(server.bucket)"))
            #expect(bucket.isDirectory)
            #expect(bucket.name == server.bucket)
            // Buckets have a creation date, which is more than a prefix can say for itself.
            #expect(bucket.modifiedAt != nil)

            await #expect(throws: SessionError.notFound(RemotePath("/no-such-bucket-here"))) {
                _ = try await session.stat(RemotePath("/no-such-bucket-here"))
            }
        }
    }

    @Test("The root is a directory, and it is the default place to start")
    func rootIsADirectory() async throws {
        try await server.withSession { session in
            // Bound before expecting: inside a closure, `#expect` does not carry a `try` out to the
            // enclosing throwing context, so the macro expansion cannot handle the error itself.
            let root = try await session.stat(.root)
            let start = try await session.defaultDirectory()
            #expect(root.isDirectory)
            #expect(start == .root)
            #expect(await session.exists(.root))
        }
    }

    // MARK: - Listing objects

    @Test("Objects and prefixes come back as files and directories")
    func listsObjectsAndPrefixes() async throws {
        let keys = ["listing-4a/a.txt", "listing-4a/nested/b.txt"]
        try await server.withSeeded(keys) { session in
            let items = try await session.list(RemotePath("/\(server.bucket)/listing-4a"))
            #expect(items.count == 2)

            let file = try #require(items.first { $0.name == "a.txt" })
            #expect(!file.isDirectory)
            #expect(file.size == 5)
            #expect(file.modifiedAt != nil)

            let directory = try #require(items.first { $0.name == "nested" })
            #expect(directory.isDirectory)
            // A prefix has no size. Reporting zero would be a claim rather than an absence.
            #expect(directory.size == nil)
        }
    }

    @Test("Listing does not recurse: a key two levels down is not in the parent's listing")
    func listingIsNotRecursive() async throws {
        let keys = ["depth-4a/a.txt", "depth-4a/nested/b.txt"]
        try await server.withSeeded(keys) { session in
            let items = try await session.list(RemotePath("/\(server.bucket)/depth-4a"))
            #expect(!items.contains { $0.name == "b.txt" })
        }
    }

    @Test("Listing something that is an object fails rather than reporting an empty directory")
    func listingAnObjectThrows() async throws {
        try await server.withSeeded(["object-4a/a.txt"]) { session in
            let file = RemotePath("/\(server.bucket)/object-4a/a.txt")
            await #expect(throws: SessionError.notADirectory(file)) {
                _ = try await session.list(file)
            }
        }
    }

    @Test("A prefix nothing lives under is not found, rather than empty")
    func missingPrefixIsNotFound() async throws {
        try await server.withSession { session in
            // The ambiguity S3 creates and a file system never does: an empty folder and a missing one
            // are the same answer from the server. This is the side of it a browser must get right, or
            // every typo opens a blank window instead of reporting a mistake.
            let missing = RemotePath("/\(server.bucket)/nothing-is-here-4a")
            await #expect(throws: SessionError.notFound(missing)) {
                _ = try await session.list(missing)
            }
            #expect(await !session.exists(missing))
        }
    }

    @Test("A directory that exists only because objects are under it is still found")
    func impliedDirectoryIsFound() async throws {
        // No placeholder object is written here — this is a folder as every other S3 tool leaves it.
        // `stat` has to fall back to asking whether anything lives under the prefix.
        try await server.withSeeded(["implied-4a/deep/a.txt"]) { session in
            let implied = RemotePath("/\(server.bucket)/implied-4a")
            let item = try await session.stat(implied)
            #expect(item.isDirectory)
            #expect(await session.exists(implied))
        }
    }

    @Test("A name full of characters that mean something in a URL survives signing")
    func awkwardNames() async throws {
        // HTTP makes this sharper than SFTP ever did: these characters are legal in a key, must be
        // percent-encoded in the URL, and must be signed in exactly the form the server canonicalises.
        // Get any one of the three wrong and the request fails with a signature mismatch.
        let key = "awkward-4a/a file with #, % and é.txt"
        try await server.withSeeded([key]) { session in
            let items = try await session.list(RemotePath("/\(server.bucket)/awkward-4a"))
            #expect(items.map(\.name) == ["a file with #, % and é.txt"])

            let item = try await session.stat(S3Location.path(bucket: server.bucket, key: key))
            #expect(item.size == 5)
        }
    }

    @Test("More than a thousand objects page rather than being cut off")
    func paginates() async throws {
        // S3 caps a listing at 1000 keys and says so with `isTruncated`. A backend that ignored that
        // would be a browser quietly lying about what is on the server — and the lie only appears in
        // directories big enough that nobody checks them by hand.
        let keys = (0..<1_100).map { "paging-4a/\(String(format: "%04d", $0)).txt" }
        try await server.withSeeded(keys) { session in
            let items = try await session.list(RemotePath("/\(server.bucket)/paging-4a"))
            #expect(items.count == 1_100)
        }
    }
}
