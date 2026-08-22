//
//  S3Location.swift
//  DriverProKit
//
//  Target responsibility
//  ────────────────────
//  DPProtocolS3 speaks the S3 REST API through Soto: ListBuckets, ListObjectsV2, HeadObject, GetObject,
//  PutObject and the multipart family. It implements `Session` and nothing else knows it exists except
//  the composition root.
//
//  It may import Foundation, DPCore, DPCredentials and SotoS3. It may NOT import SwiftUI, AppKit, or any
//  other DPProtocol* target.
//

import DPCore
import Foundation

/// Where a ``RemotePath`` lands in S3's namespace.
///
/// The one idea worth understanding about this backend: **S3 has no paths.** It has buckets, and inside
/// each bucket a flat set of keys that only *look* hierarchical because people put slashes in them.
/// `/photos/2024/x.jpg` is not a file inside a folder; it is the key `2024/x.jpg` in the bucket
/// `photos`.
///
/// So every path is one of three things, and they are not variations on each other — they take different
/// requests and obey different rules:
///
/// ```
/// /                    .root                     ListBuckets
/// /photos              .bucket("photos")         the bucket itself
/// /photos/2024/x.jpg   .object("photos", "2024/x.jpg")
/// ```
///
/// This is `WebDAVPaths`' counterpart, and the comparison is worth making. There, a path became a URL by
/// gaining a configured prefix — the same *kind* of thing throughout. Here the first component changes
/// what the request *is*. That is why the root is not a directory, and why writing to it is refused
/// rather than merely unsupported. See ADR 017.
///
/// ## The keys this cannot represent, and why that is not yet a problem
/// S3 keys are arbitrary strings; `RemotePath` components are normalised. So the legal key `a//b.txt`
/// becomes `/bucket/a/b.txt` and maps *back* to `a/b.txt` — a different object — and a key ending in `/`
/// that has real content is indistinguishable here from a directory placeholder.
///
/// Slice 4a is browsing, which cannot damage anything, so such keys are listed as they are rather than
/// hidden. **Slice 4b must handle this before `delete` and `write` land**, where the consequence stops
/// being a cosmetic mismatch and becomes an operation applied to the wrong object.
///
/// ## Swift note — an `enum` with associated values as a parser's output
/// Each case carries exactly the data that case needs: `.root` carries nothing, because there is nothing
/// to carry. A struct with `bucket: String?` and `key: String?` would allow a key with no bucket, which
/// is not a thing that exists. Making illegal states unrepresentable, again — the same technique
/// ``Credentials/Method`` uses.
enum S3Location: Hashable, Sendable {

    /// The account itself. Lists buckets; holds no objects.
    case root

    /// One bucket, as a whole.
    case bucket(String)

    /// One object inside a bucket. The key never begins with `/`.
    case object(bucket: String, key: String)

    // MARK: - In

    /// Splits a path into the bucket and key it names.
    ///
    /// - Parameter path: A path as the rest of DriverPro sees it.
    init(_ path: RemotePath) {
        var components = path.components
        guard !components.isEmpty else {
            self = .root
            return
        }
        let bucket = components.removeFirst()
        self = components.isEmpty
            ? .bucket(bucket)
            : .object(bucket: bucket, key: components.joined(separator: "/"))
    }

    // MARK: - Out

    /// Rebuilds the path a bucket and key came from.
    ///
    /// - Parameters:
    ///   - bucket: The bucket's name.
    ///   - key: The object key. A trailing `/` — which a directory placeholder has — is normalised away
    ///     by ``RemotePath``, so the placeholder and the prefix it stands for are one path.
    /// - Returns: The path.
    static func path(bucket: String, key: String) -> RemotePath {
        RemotePath(components: [bucket] + key.split(separator: "/").map(String.init))
    }

    /// The bucket this location is in, or `nil` at the root.
    var bucket: String? {
        switch self {
        case .root: nil
        case .bucket(let name): name
        case .object(let bucket, _): bucket
        }
    }

    /// The object key, or `nil` when the location is not an object.
    var key: String? {
        if case .object(_, let key) = self { return key }
        return nil
    }

    /// The key prefix that lists this location's immediate children.
    ///
    /// Empty for a bucket — everything in it is a child — and `key + "/"` for anything deeper. The
    /// trailing slash is what makes `ListObjectsV2`'s delimiter work: without it, listing `2024` would
    /// also return `2024-archive/`, because S3 matches a prefix as a string and knows nothing about
    /// path boundaries.
    ///
    /// `nil` at the root, which is listed with a different request entirely.
    var childPrefix: String? {
        switch self {
        case .root: nil
        case .bucket: ""
        case .object(_, let key): "\(key)/"
        }
    }

    /// The key a zero-byte placeholder object would have, marking this location as a directory.
    ///
    /// `nil` for the root and for a bucket, neither of which needs one: a bucket exists on its own.
    var placeholderKey: String? {
        if case .object(_, let key) = self { return "\(key)/" }
        return nil
    }
}
