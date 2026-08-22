//
//  S3LocationTests.swift
//  DPProtocolS3Tests
//

import DPCore
import Foundation
import Testing
@testable import DPProtocolS3

/// Splitting a path into a bucket and a key, and putting it back together.
///
/// Offline and hermetic: this is string arithmetic, and it is the part of the backend that everything
/// else is built on. A bucket parsed wrong is a request sent to the wrong place.
@Suite("S3 locations")
struct S3LocationTests {

    @Test("The root is neither a bucket nor a key")
    func rootIsItsOwnThing() {
        #expect(S3Location(.root) == .root)
        #expect(S3Location(.root).bucket == nil)
        #expect(S3Location(.root).key == nil)
        // Not "" — the root is listed by a different request entirely, and a prefix of "" would be a
        // listing of the first bucket's contents rather than of the buckets.
        #expect(S3Location(.root).childPrefix == nil)
    }

    @Test("A single component is a bucket, not an object in one")
    func oneComponentIsABucket() {
        #expect(S3Location(RemotePath("/photos")) == .bucket("photos"))
        #expect(S3Location(RemotePath("/photos")).key == nil)
        // Empty: everything in the bucket is a child of it, so nothing narrows the listing.
        #expect(S3Location(RemotePath("/photos")).childPrefix == "")
    }

    @Test("Everything after the first component is one key")
    func deeperIsAKey() {
        #expect(S3Location(RemotePath("/photos/2024/summer/x.jpg"))
            == .object(bucket: "photos", key: "2024/summer/x.jpg"))
    }

    @Test("A key never starts with a slash")
    func keysAreRelative() throws {
        let key = try #require(S3Location(RemotePath("/photos/a.txt")).key)
        #expect(!key.hasPrefix("/"))
        #expect(key == "a.txt")
    }

    @Test("A child prefix ends in a slash, so a sibling with a longer name is not swept in")
    func childPrefixEndsInSlash() {
        // Without the trailing slash, listing `2024` would also return everything under `2024-archive`:
        // S3 matches a prefix as a string and knows nothing about path boundaries.
        #expect(S3Location(RemotePath("/photos/2024")).childPrefix == "2024/")
    }

    @Test("A path survives the round trip through bucket and key")
    func roundTrip() {
        let original = RemotePath("/photos/2024/summer/x.jpg")
        let location = S3Location(original)
        #expect(S3Location.path(bucket: location.bucket ?? "", key: location.key ?? "") == original)
    }

    @Test("A directory placeholder and the prefix it stands for are one path")
    func placeholderNormalises() {
        // The zero-byte key `2024/` and the prefix `2024/` are the same folder, and `RemotePath` makes
        // them the same value — which is what stops a folder appearing twice in its parent's listing.
        #expect(S3Location.path(bucket: "photos", key: "2024/") == RemotePath("/photos/2024"))
        #expect(S3Location(RemotePath("/photos/2024")).placeholderKey == "2024/")
        #expect(S3Location(RemotePath("/photos")).placeholderKey == nil)
    }

    @Test("A name containing characters that mean something in a URL survives")
    func awkwardNames() throws {
        // The characters that break naive URL building. They are legal in a key, and S3 signs the
        // encoded form — so the round trip has to preserve them exactly.
        let original = RemotePath("/photos/a file with #, % and é.txt")
        let location = S3Location(original)
        #expect(location.key == "a file with #, % and é.txt")
        #expect(S3Location.path(bucket: "photos", key: location.key ?? "") == original)
    }
}
