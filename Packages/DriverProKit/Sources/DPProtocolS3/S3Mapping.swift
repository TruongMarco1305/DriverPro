//
//  S3Mapping.swift
//  DPProtocolS3
//

import DPCore
import Foundation
import SotoCore
import SotoS3

// MARK: - Listings to items

extension S3.Object {
    /// Turns one listed object into a ``RemoteItem``, or `nil` if it is not one.
    ///
    /// Returns `nil` for the directory placeholder — the zero-byte key ending in `/` that
    /// ``S3Location/placeholderKey`` writes. `ListObjectsV2` returns it in `Contents` alongside the real
    /// objects, so without this a folder would appear inside itself as an empty file with a blank name.
    ///
    /// - Parameter bucket: Which bucket this listing came from.
    /// - Returns: The entry, or `nil` if the key is a placeholder or missing.
    func makeItem(inBucket bucket: String) -> RemoteItem? {
        guard let key, !key.hasSuffix("/") else { return nil }
        return RemoteItem(
            path: S3Location.path(bucket: bucket, key: key),
            kind: .file,
            size: size,
            modifiedAt: lastModified,
            // The ETag is worth carrying even though `.checksum` is off: for a single-part upload it is
            // the MD5, which is enough to tell two versions of a file apart in a diagnostic. It is *not*
            // enough to verify a multipart upload, which is exactly why the capability stays off.
            extra: eTag.map { ["s3.etag": $0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))] } ?? [:]
        )
    }
}

extension S3.CommonPrefix {
    /// Turns a common prefix into a directory entry.
    ///
    /// A "folder" in S3 is this: a prefix that several keys share. It has no size, no date and no
    /// existence of its own — delete everything under it and it stops being listed.
    ///
    /// - Parameter bucket: Which bucket this listing came from.
    /// - Returns: The directory, or `nil` if the server sent no prefix.
    func makeItem(inBucket bucket: String) -> RemoteItem? {
        guard let prefix else { return nil }
        return RemoteItem(
            path: S3Location.path(bucket: bucket, key: prefix),
            kind: .directory,
            // Deliberately nil rather than 0. A prefix has no size, and reporting zero would be a claim
            // rather than an absence — the same distinction `RemoteItem.size` exists to preserve.
            size: nil,
            modifiedAt: nil
        )
    }
}

extension S3.Bucket {
    /// Turns a bucket into a top-level directory entry.
    ///
    /// Buckets are shown as directories because that is what they behave like to someone browsing: you
    /// open one and find things inside. What they are *not* is a directory you can put an object into
    /// directly at the root — see ``S3Session``'s refusals.
    ///
    /// - Returns: The entry, or `nil` if the server sent no name.
    func makeItem() -> RemoteItem? {
        guard let name else { return nil }
        return RemoteItem(
            path: RemotePath(components: [name]),
            kind: .directory,
            size: nil,
            // Buckets do have a creation date, which is more than a prefix can say for itself.
            modifiedAt: creationDate,
            extra: bucketRegion.map { ["s3.region": $0] } ?? [:]
        )
    }
}

// MARK: - Errors

/// Translates Soto's errors into ones the rest of DriverPro can act on.
enum S3ErrorMapping {

    /// Runs a probe that is allowed to find nothing, and refuses to hide anything else.
    ///
    /// S3 has no `stat`, so describing a path means trying two or three requests and seeing which one
    /// answers. The obvious way to write that is `try?` — and it is wrong, because it turns *every*
    /// failure into "not there": a 403, a signature mismatch, a dropped connection, and worst of all a
    /// wrong-region redirect, which ``map(_:path:)`` goes to some trouble to turn into a message naming
    /// the region to use. Swallowed, the most common way a correct S3 bookmark fails becomes the least
    /// diagnosable one.
    ///
    /// It matters above this file too. A transient failure reported as ``SessionError/notFound(_:)`` is
    /// not retryable, so `TransferQueue` gives up on something a second attempt would have got.
    ///
    /// - Parameters:
    ///   - path: What the probe is about.
    ///   - probe: The request to make.
    /// - Returns: The probe's result, or `nil` if the server genuinely has nothing there.
    /// - Throws: The mapped error for any failure that is *not* a plain absence.
    static func missing<T>(
        _ path: RemotePath,
        _ probe: () async throws -> T
    ) async throws -> T? {
        do {
            return try await probe()
        } catch {
            let mapped = map(error, path: path)
            if case .notFound = mapped { return nil }
            throw mapped
        }
    }

    /// Maps whatever Soto threw onto a ``SessionError``.
    ///
    /// **Matched on the error code and the HTTP status, not on Soto's typed cases.** That is deliberate:
    /// `S3ErrorType` models the codes *Amazon* documents, and the whole point of this backend is that
    /// most of the servers it talks to are not Amazon. A MinIO or a Backblaze returning a code Soto has
    /// no case for arrives as an `AWSResponseError`, and matching on the string handles both.
    ///
    /// - Parameters:
    ///   - error: What Soto threw.
    ///   - path: What the request was about, for the error that names it.
    /// - Returns: The mapped error, or a `transport` failure carrying the original text when nothing
    ///   more specific fits — never a silent swallow.
    static func map(_ error: any Error, path: RemotePath) -> SessionError {
        if let session = error as? SessionError { return session }

        guard let aws = error as? any AWSErrorType else {
            // The type name is carried as well as the text because several of the errors that reach here
            // come from AsyncHTTPClient rather than from S3, and their `description` can be a single
            // word — `limit`, `cancelled` — which names a case without naming what raised it.
            return .transport("\(type(of: error)): \(error)")
        }

        let status = aws.context?.responseCode.code
        switch aws.errorCode {
        case "NoSuchKey", "NoSuchBucket", "NotFound":
            return .notFound(path)
        case "AccessDenied", "AllAccessDisabled":
            return .accessDenied(path)
        case "InvalidAccessKeyId", "SignatureDoesNotMatch", "InvalidSecurity":
            return .authenticationFailed(reason: aws.message ?? "The server rejected these credentials.")
        case "BucketAlreadyExists", "BucketAlreadyOwnedByYou":
            return .alreadyExists(path)
        case "BucketNotEmpty":
            return .directoryNotEmpty(path)
        case "PermanentRedirect", "AuthorizationHeaderMalformed":
            // The one error that names its own fix. A bucket lives in exactly one region, and asking the
            // wrong one is the most common way an otherwise-correct S3 bookmark fails — so say which
            // region to use rather than reporting a redirect the user cannot follow.
            let correct = aws.context?.headers["x-amz-bucket-region"].first
                ?? aws.context?.additionalFields["Region"]
            return .protocolViolation(
                correct.map { "This bucket is in region \($0). Change the bookmark's region to match." }
                    ?? (aws.message ?? "The server redirected the request to another region.")
            )
        default:
            break
        }

        switch status {
        case 401, 403: return .accessDenied(path)
        case 404, 410: return .notFound(path)
        case 409: return .alreadyExists(path)
        case 507: return .insufficientStorage
        default: return .transport("\(aws.errorCode): \(aws.message ?? String(describing: error))")
        }
    }
}
