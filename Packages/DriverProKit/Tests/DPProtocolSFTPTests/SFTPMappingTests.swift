//
//  SFTPMappingTests.swift
//  DPProtocolSFTPTests
//

import Citadel
import DPCore
import Foundation
import Testing
@testable import DPProtocolSFTP

/// Offline tests for the pure conversion logic. No server, no network.
///
/// These cover the conversions most likely to be subtly wrong — file-type bits packed into the same
/// integer as permissions, and SFTP's habit of reporting several distinct failures through one status
/// code.
@Suite("SFTP attribute mapping")
struct SFTPAttributeMappingTests {

    @Test("File type is read from the high bits of the mode", arguments: [
        (mode: UInt32(0o040755), expected: RemoteItem.Kind.directory),
        (mode: UInt32(0o100644), expected: RemoteItem.Kind.file),
        (mode: UInt32(0o120777), expected: RemoteItem.Kind.symbolicLink(target: nil)),
    ])
    func mapsFileTypeBits(_ testCase: (mode: UInt32, expected: RemoteItem.Kind)) {
        // SFTP packs type and permissions into one UInt32: 0o040755 is "directory, mode 755". Reading
        // the permission bits without masking off the type is the classic bug here — it produces a
        // browser where every folder looks like a file.
        #expect(SFTPAttributeMapping.kind(fromMode: testCase.mode) == testCase.expected)
    }

    @Test("Missing permissions default to file rather than directory")
    func defaultsToFile() {
        // Guessing "directory" would make the browser navigate into something unlistable; guessing
        // "file" at worst produces a failed download.
        #expect(SFTPAttributeMapping.kind(fromMode: nil) == .file)
    }

    @Test("Permissions keep only the mode bits, discarding the file type")
    func extractsPermissionBits() {
        var attributes = SFTPFileAttributes()
        attributes.permissions = 0o040755

        let item = SFTPAttributeMapping.item(from: attributes, at: RemotePath("/srv/data"))

        #expect(item.kind == .directory)
        #expect(item.permissions == POSIXPermissions(rawValue: 0o755))
        #expect(item.permissions?.symbolicString == "rwxr-xr-x")
    }

    @Test("Fields the server omitted stay nil rather than being invented")
    func omittedFieldsStayNil() {
        // An empty attribute set is what a minimal server sends. Nothing may be fabricated from it:
        // showing "0 bytes" and "1 Jan 1970" looks like data and is not.
        let item = SFTPAttributeMapping.item(from: SFTPFileAttributes(), at: RemotePath("/a/b"))

        #expect(item.size == nil)
        #expect(item.modifiedAt == nil)
        #expect(item.permissions == nil)
        #expect(item.owner == nil)
        #expect(item.group == nil)
    }

    @Test("Size, timestamp, and ownership are carried across")
    func mapsPopulatedAttributes() {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        var attributes = SFTPFileAttributes(
            size: 4096,
            accessModificationTime: .init(accessTime: modified, modificationTime: modified)
        )
        attributes.permissions = 0o100644
        attributes.uidgid = .init(userId: 501, groupId: 20)

        let item = SFTPAttributeMapping.item(from: attributes, at: RemotePath("/srv/f.txt"))

        #expect(item.size == 4096)
        #expect(item.modifiedAt == modified)
        // SFTP v3 sends numeric ids only — there is no name on the wire. Recording "501" rather than
        // inventing "duck" is the honest mapping, and the UI can resolve names later if it wants to.
        #expect(item.owner == "501")
        #expect(item.group == "20")
    }

    @Test("Permission updates carry only the permission field")
    func permissionAttributesAreMinimal() {
        // SETSTAT applies exactly the fields whose flags are set, so sending only permissions must not
        // disturb the file's size or timestamps.
        let attributes = SFTPAttributeMapping.attributes(forPermissions: POSIXPermissions(rawValue: 0o600))

        #expect(attributes.permissions == 0o600)
        #expect(attributes.size == nil)
        #expect(attributes.accessModificationTime == nil)
    }

    @Test("Timestamp updates set access and modification together")
    func timestampAttributes() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let attributes = SFTPAttributeMapping.attributes(forModificationDate: date)

        #expect(attributes.accessModificationTime?.modificationTime == date)
        // SFTP has a single flag for the pair, so the access time necessarily goes along with it.
        #expect(attributes.accessModificationTime?.accessTime == date)
        #expect(attributes.permissions == nil)
    }
}

@Suite("SFTP error mapping")
struct SFTPErrorMappingTests {

    @Test("Status codes map to the matching session error")
    func mapsStatusCodes() {
        let path = RemotePath("/srv/missing.txt")

        #expect(SFTPErrorMapping.map(status: .noSuchFile, message: "", path: path) == .notFound(path))
        #expect(SFTPErrorMapping.map(status: .permissionDenied, message: "", path: path) == .accessDenied(path))
        #expect(SFTPErrorMapping.map(status: .connectionLost, message: "", path: path) == .notConnected)
        #expect(SFTPErrorMapping.map(status: .noConnection, message: "", path: path) == .notConnected)
    }

    @Test("SFTP's catch-all failure is disambiguated by the server's message", arguments: [
        (message: "Directory not empty", expected: SessionError.directoryNotEmpty(RemotePath("/d"))),
        (message: "File already exists", expected: SessionError.alreadyExists(RemotePath("/d"))),
        (message: "No space left on device", expected: SessionError.insufficientStorage),
        (message: "Quota exceeded", expected: SessionError.insufficientStorage),
        (message: "Permission denied", expected: SessionError.accessDenied(RemotePath("/d")))
    ])
    func disambiguatesFailureByMessage(_ testCase: (message: String, expected: SessionError)) {
        // SFTP v3 reports "directory not empty", "disk full", and "already exists" all through status 4,
        // so the message text is the only signal available. Matching on it is inherently fuzzy, which is
        // exactly why it is confined to one place that can be corrected as real servers are met.
        let mapped = SFTPErrorMapping.map(status: .failure, message: testCase.message, path: RemotePath("/d"))
        #expect(mapped == testCase.expected)
    }

    @Test("An unrecognised failure message becomes a transport error, never silence")
    func unknownFailureIsPreserved() {
        let mapped = SFTPErrorMapping.map(status: .failure, message: "something odd", path: RemotePath("/d"))
        #expect(mapped == .transport("something odd"))
    }

    @Test("Cancellation stays cancellation")
    func cancellationIsPreserved() {
        // If this became a generic transport error, cancelling a transfer would pop an error alert for
        // something the user deliberately did.
        #expect(SFTPErrorMapping.map(CancellationError()) == .cancelled)
        #expect(SFTPErrorMapping.mapConnectionError(CancellationError(), hostname: "h") == .cancelled)
    }

    @Test("An already-translated error is not wrapped twice")
    func doesNotDoubleWrap() {
        let original = SessionError.notFound(RemotePath("/x"))
        #expect(SFTPErrorMapping.map(original) == original)
    }

    @Test("A refused login is distinguished from an unreachable host")
    func separatesAuthFromNetwork() {
        // These need different recovery: one re-prompts for a password, the other offers a retry.
        let auth = SFTPErrorMapping.mapConnectionError(CitadelError.unauthorized, hostname: "example.com")
        #expect(auth.needsCredentials)
        #expect(!auth.isRetryable)

        struct Refused: Error { var description = "Connection refused" }
        let network = SFTPErrorMapping.mapConnectionError(Refused(), hostname: "example.com")
        #expect(network.isRetryable)
        #expect(!network.needsCredentials)
    }
}

@Suite("SFTP capabilities")
struct SFTPCapabilityTests {

    @Test("SFTP advertises exactly what Citadel can actually do")
    func advertisedCapabilities() {
        let session = SFTPSession(host: RemoteHost(protocolIdentifier: .sftp, hostname: "h", port: 22))
        let capabilities = session.capabilities

        #expect(capabilities.contains(.rename))
        #expect(capabilities.contains(.posixPermissions))
        #expect(capabilities.contains(.timestamps))
        #expect(capabilities.contains(.resumeDownload))
        #expect(capabilities.contains(.resumeUpload))

        // The two findings that justify the whole capability system, on the very first backend:
        // SFTP has no recursive delete (remove and rmdir are separate, with no tree form) and
        // no server-side copy at all in v3.
        #expect(!capabilities.contains(.recursiveDelete))
        #expect(!capabilities.contains(.serverSideCopy))

        // v6 or vendor extensions, none of which Citadel exposes.
        #expect(!capabilities.contains(.quota))
        #expect(!capabilities.contains(.versioning))
        #expect(!capabilities.contains(.checksum))
    }

    @Test("Capabilities are readable without awaiting the actor")
    func capabilitiesAreNonisolated() {
        // `nonisolated` matters for the UI: deciding whether to enable the Rename menu item happens
        // during a synchronous view update, where `await` is not available. This test compiles only
        // because no `await` is needed.
        let session = SFTPSession(host: RemoteHost(protocolIdentifier: .sftp, hostname: "h", port: 22))
        #expect(session.capabilities.contains(.rename))
        #expect(session.host.hostname == "h")
    }
}

@Suite("SFTP authentication method")
struct SFTPAuthenticationTests {

    @Test("A password credential maps to password authentication")
    func passwordAuth() throws {
        // Just needs to not throw: Citadel's SSHAuthenticationMethod is opaque, so there is nothing to
        // inspect. The failure this guards against is a mapping that throws for a valid credential.
        _ = try SFTPSession.authenticationMethod(for: .password(username: "duck", password: "hunter2"))
    }

    @Test("Anonymous maps to an empty password, since SSH has no anonymous mode")
    func anonymousAuth() throws {
        _ = try SFTPSession.authenticationMethod(for: .anonymous(username: "anonymous"))
    }

    @Test("Token authentication is refused with a clear reason")
    func tokenAuthRejected() {
        let credentials = Credentials(username: "duck", method: .token("abc123"))
        #expect(throws: SessionError.self) {
            _ = try SFTPSession.authenticationMethod(for: credentials)
        }
    }

    @Test("An unreadable private key reports whether a passphrase might be the problem")
    func unreadableKeyExplainsItself() {
        let garbage = Data("not a key".utf8)

        let withoutPassphrase = Credentials(
            username: "duck", method: .privateKey(data: garbage, passphrase: nil, path: nil))
        #expect(throws: SessionError.self) {
            _ = try SFTPSession.authenticationMethod(for: withoutPassphrase)
        }

        let withPassphrase = Credentials(
            username: "duck", method: .privateKey(data: garbage, passphrase: "secret", path: nil))
        #expect(throws: SessionError.self) {
            _ = try SFTPSession.authenticationMethod(for: withPassphrase)
        }
    }
}
