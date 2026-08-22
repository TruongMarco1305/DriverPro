//
//  S3MappingTests.swift
//  DPProtocolS3Tests
//

import DPCore
import Foundation
import SotoCore
import Testing
@testable import DPProtocolS3

/// Turning what the server said into something a person can act on.
///
/// The error tests use `AWSResponseError`, which is what Soto produces for a code it has no typed case
/// for — and that is the realistic shape here rather than a shortcut. Most of the servers this backend
/// talks to are not Amazon, so a code Soto never generated for is the *normal* path, not the edge.
@Suite("S3 mapping")
struct S3MappingTests {

    private let path = RemotePath("/photos/a.txt")

    @Test("A missing key or bucket is a missing path")
    func notFound() {
        for code in ["NoSuchKey", "NoSuchBucket", "NotFound"] {
            #expect(S3ErrorMapping.map(AWSResponseError(errorCode: code), path: path) == .notFound(path))
        }
    }

    @Test("Refused access says so, rather than reporting a transport failure")
    func accessDenied() {
        #expect(S3ErrorMapping.map(AWSResponseError(errorCode: "AccessDenied"), path: path)
            == .accessDenied(path))
    }

    @Test("Bad keys are an authentication failure, which is the one the connection sheet can act on")
    func badCredentials() throws {
        let mapped = S3ErrorMapping.map(AWSResponseError(errorCode: "InvalidAccessKeyId"), path: path)
        guard case .authenticationFailed = mapped else {
            Issue.record("expected authenticationFailed, got \(mapped)")
            return
        }
        // The distinction that matters: `needsCredentials` is what makes the app re-ask for a password
        // rather than giving up.
        #expect(mapped.needsCredentials)
    }

    @Test("A bucket that already exists is not an error about the request")
    func alreadyExists() {
        for code in ["BucketAlreadyExists", "BucketAlreadyOwnedByYou"] {
            #expect(S3ErrorMapping.map(AWSResponseError(errorCode: code), path: path)
                == .alreadyExists(path))
        }
    }

    @Test("A wrong region is reported as a wrong region, not as a redirect")
    func wrongRegion() throws {
        // The most common way an otherwise-correct S3 bookmark fails. A user cannot follow a redirect;
        // they can change a region, so the message has to be about the region.
        let mapped = S3ErrorMapping.map(AWSResponseError(errorCode: "PermanentRedirect"), path: path)
        guard case .protocolViolation(let reason) = mapped else {
            Issue.record("expected protocolViolation, got \(mapped)")
            return
        }
        #expect(reason.lowercased().contains("region"))
    }

    @Test("An error nobody anticipated keeps its text rather than being swallowed")
    func unknownCode() throws {
        // The failure mode this guards against is a backend that maps everything it does not recognise
        // to one bland error, leaving nothing to diagnose a compatible server's quirk with.
        let mapped = S3ErrorMapping.map(AWSResponseError(errorCode: "SomeVendorSpecificFailure"), path: path)
        guard case .transport(let reason) = mapped else {
            Issue.record("expected transport, got \(mapped)")
            return
        }
        #expect(reason.contains("SomeVendorSpecificFailure"))
    }

    @Test("A SessionError passes through rather than being wrapped in itself")
    func passThrough() {
        #expect(S3ErrorMapping.map(SessionError.notConnected, path: path) == .notConnected)
    }

    // MARK: - Probes that may find nothing, but must not hide anything else

    @Test("A probe that finds nothing returns nothing, so the next one can be tried")
    func missingReturnsNil() async throws {
        // Typed explicitly: a closure whose only statement is a `throw` infers `Void`, and `Void?`
        // compared against nil is a warning rather than the check intended here.
        let found: Int? = try await S3ErrorMapping.missing(path) {
            throw AWSResponseError(errorCode: "NoSuchKey")
        }
        #expect(found == nil)
    }

    @Test("A probe that succeeds returns its result")
    func missingPassesResultThrough() async throws {
        let found = try await S3ErrorMapping.missing(path) { 42 }
        #expect(found == 42)
    }

    @Test("A refusal is not an absence, and must reach the caller")
    func missingDoesNotHideAccessDenied() async throws {
        // The bug this exists to prevent: `try?` around each of `stat`'s probes turned "you may not look
        // at this" into "there is nothing here", which is a different thing to tell a user and a
        // different thing for them to do about it.
        await #expect(throws: SessionError.accessDenied(path)) {
            _ = try await S3ErrorMapping.missing(path) {
                throw AWSResponseError(errorCode: "AccessDenied")
            }
        }
    }

    @Test("A wrong region survives the probe rather than being reported as a missing file")
    func missingDoesNotHideWrongRegion() async throws {
        // The one that matters most. `map` turns a redirect into a message naming the region to use;
        // swallowing it made the most common S3 misconfiguration the least diagnosable.
        var thrown: SessionError?
        do {
            _ = try await S3ErrorMapping.missing(path) {
                throw AWSResponseError(errorCode: "PermanentRedirect")
            }
        } catch let error as SessionError {
            thrown = error
        }
        let error = try #require(thrown)
        guard case .protocolViolation(let reason) = error else {
            Issue.record("expected protocolViolation, got \(error)")
            return
        }
        #expect(reason.lowercased().contains("region"))
    }

    @Test("A transport failure stays retryable instead of becoming a permanent absence")
    func missingKeepsFailuresRetryable() async throws {
        // `list` calls `stat` on an empty result, so a swallowed network error would surface as
        // `notFound` — and `isRetryable` is false for that, so `TransferQueue` would abandon something a
        // second attempt would have got.
        var thrown: SessionError?
        do {
            _ = try await S3ErrorMapping.missing(path) {
                throw URLError(.networkConnectionLost)
            }
        } catch let error as SessionError {
            thrown = error
        }
        let error = try #require(thrown)
        #expect(error.isRetryable)
    }

    @Test("The endpoint a bookmark describes")
    func endpoints() {
        var host = RemoteHost(protocolIdentifier: .s3, hostname: "s3.amazonaws.com", port: 443)
        // The default port is left off, so the endpoint reads the way a server writes it in its logs.
        #expect(S3Client.endpoint(for: host) == "https://s3.amazonaws.com")

        host.port = 9000
        host.properties[S3Client.allowsInsecureKey] = "true"
        #expect(S3Client.endpoint(for: host) == "http://s3.amazonaws.com:9000")
    }
}
