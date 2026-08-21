//
//  DuckFormatTests.swift
//  DPBookmarksTests
//

import DPCore
import DPDatabase
import Foundation
import Testing
@testable import DPBookmarks

/// The `.duck` fixtures, written out rather than bundled.
///
/// The test is then the format's documentation: what Cyberduck writes is visible here, in the shape it
/// writes it, including the detail everything hinges on — **every scalar is a `<string>`, `Port`
/// included**.
enum DuckFixture {

    /// Wraps key/value XML in the plist envelope Cyberduck writes.
    static func plist(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(body)
        </dict>
        </plist>
        """.utf8)
    }

    /// A fully filled-in SFTP bookmark, with a key and settings DriverPro has no field for.
    static let sftp = plist("""
        <key>Protocol</key><string>sftp</string>
        <key>Provider</key><string>iterate GmbH</string>
        <key>UUID</key><string>4C3F0F2E-7A8B-4C1D-9E2F-0A1B2C3D4E5F</string>
        <key>Nickname</key><string>Work</string>
        <key>Hostname</key><string>example.com</string>
        <key>Port</key><string>2222</string>
        <key>Username</key><string>duck</string>
        <key>Path</key><string>/srv/www</string>
        <key>Comment</key><string>Staging box, EU</string>
        <key>Timezone</key><string>Europe/Zurich</string>
        <key>Labels</key>
        <array><string>work</string><string>eu</string></array>
        <key>Private Key File Dictionary</key>
        <dict>
            <key>Path</key><string>~/.ssh/id_ed25519</string>
            <key>Bookmark</key><string>Ym9va21hcmtkYXRh</string>
        </dict>
        <key>Workdir Dictionary</key>
        <dict><key>Path</key><string>/srv</string></dict>
        """)

    /// A real SFTP bookmark, exported from Cyberduck. Transcribed verbatim.
    ///
    /// This is the file the mapping was checked against field by field: a non-default port written as a
    /// string, an empty `Labels` array, and two keys DriverPro has no field for.
    static let realSFTPBookmark = plist("""
        <key>Protocol</key><string>sftp</string>
        <key>Provider</key><string>iterate GmbH</string>
        <key>Nickname</key><string>fessior-dev</string>
        <key>UUID</key><string>d88bb6e5-2b5b-4c81-a4fa-9b1ecb474f21</string>
        <key>Hostname</key><string>61.28.226.131</string>
        <key>Port</key><string>234</string>
        <key>Username</key><string>stackops</string>
        <key>Encoding</key><string>UTF-8</string>
        <key>Access Timestamp</key><string>1787163977250</string>
        <key>Labels</key>
        <array>
        </array>
        """)

    /// The real file found in `~/Downloads`: a bundled FTP profile, five keys, nothing else.
    static let realFTPProfile = plist("""
        <key>Protocol</key><string>ftp</string>
        <key>Provider</key><string>iterate GmbH</string>
        <key>UUID</key><string>1fd4f5d7-78c5-487c-a8c1-26c1eb5dcf27</string>
        <key>Hostname</key><string>www.googleapis.com</string>
        <key>Port</key><string>21</string>
        """)
}

@Suite("DuckFormat — decoding")
struct DuckDecodingTests {

    private let supported: Set<ProtocolIdentifier> = [.sftp]

    private func decode(_ data: Data) -> DuckDecoding {
        DuckFormat.decode(data, supported: supported)
    }

    private func bookmark(_ data: Data) throws -> RemoteHost {
        guard case .bookmark(let host) = decode(data) else {
            Issue.record("expected a bookmark, got \(decode(data))")
            throw DecodingFailure.notABookmark
        }
        return host
    }

    private enum DecodingFailure: Error { case notABookmark }

    @Test("Every field DriverPro models comes across")
    func mapsEveryField() throws {
        let host = try bookmark(DuckFixture.sftp)

        #expect(host.protocolIdentifier == .sftp)
        #expect(host.hostname == "example.com")
        #expect(host.port == 2222)
        #expect(host.username == "duck")
        #expect(host.defaultPath == RemotePath("/srv/www"))
        #expect(host.nickname == "Work")
        #expect(host.comment == "Staging box, EU")
        #expect(host.id.uuidString == "4C3F0F2E-7A8B-4C1D-9E2F-0A1B2C3D4E5F")
    }

    @Test("A bookmark naming a key file authenticates with it")
    func mapsThePrivateKey() throws {
        // The path arrives abbreviated — Cyberduck serialises a `Local` with `getAbbreviatedPath` — so
        // it has to be expanded, or the file is looked for at a literal "~/.ssh/…".
        let host = try bookmark(DuckFixture.sftp)
        let expected = NSString(string: "~/.ssh/id_ed25519").expandingTildeInPath

        #expect(host.authenticationPreference == .privateKey(path: expected))
        #expect(!expected.hasPrefix("~"), "the tilde has to be gone, or nothing can open the file")
    }

    @Test("The legacy Private Key File string is read too")
    func readsTheLegacyKeyString() throws {
        // Older Cyberduck wrote a bare string. Files written then are still in people's folders.
        let host = try bookmark(DuckFixture.plist("""
            <key>Protocol</key><string>sftp</string>
            <key>Hostname</key><string>example.com</string>
            <key>Private Key File</key><string>~/.ssh/id_rsa</string>
            """))

        #expect(host.authenticationPreference
                == .privateKey(path: NSString(string: "~/.ssh/id_rsa").expandingTildeInPath))
    }

    @Test("A bookmark with no key stays on a password")
    func noKeyMeansPassword() throws {
        let host = try bookmark(DuckFixture.plist("""
            <key>Protocol</key><string>sftp</string>
            <key>Hostname</key><string>example.com</string>
            """))

        #expect(host.authenticationPreference == .password)
    }

    @Test("Only Protocol and Hostname are actually needed")
    func minimalBookmark() throws {
        // Cyberduck skips every other key in silence, and so must we: half its own bundled profiles
        // carry nothing but these.
        let host = try bookmark(DuckFixture.plist("""
            <key>Protocol</key><string>sftp</string>
            <key>Hostname</key><string>example.com</string>
            """))

        #expect(host.port == 22, "no Port means the protocol's default")
        #expect(host.username == nil)
        #expect(host.nickname == nil)
        #expect(host.defaultPath == nil)
    }

    @Test("The port is read from a string, because that is what Cyberduck writes")
    func portIsAString() throws {
        #expect(try bookmark(DuckFixture.sftp).port == 2222)
    }

    @Test("A port that is not a number falls back rather than failing the file")
    func unparseablePortFallsBack() throws {
        // The rest of the bookmark is still worth having, and a wrong port is visible and fixable.
        let host = try bookmark(DuckFixture.plist("""
            <key>Protocol</key><string>sftp</string>
            <key>Hostname</key><string>example.com</string>
            <key>Port</key><string>not a number</string>
            """))

        #expect(host.port == 22)
    }

    @Test("A protocol we cannot speak is reported, not imported")
    func unsupportedProtocol() {
        let webdav = DuckFixture.plist("""
            <key>Protocol</key><string>davs</string>
            <key>Hostname</key><string>cloud.example.com</string>
            """)

        #expect(decode(webdav) == .unsupported(.webdav))
    }

    @Test("The real bundled FTP profile reads as FTP, unsupported today")
    func realFileFromDownloads() {
        // Confirms empirically what the source only claimed: Protocol is "ftp" and Port is a string.
        #expect(decode(DuckFixture.realFTPProfile) == .unsupported(.ftp))

        guard case .bookmark(let host) = DuckFormat.decode(DuckFixture.realFTPProfile,
                                                          supported: [.ftp], defaultPort: 21) else {
            Issue.record("expected a bookmark once FTP is supported")
            return
        }
        #expect(host.hostname == "www.googleapis.com")
        #expect(host.port == 21)
    }

    @Test("A real bookmark exported from Cyberduck maps field for field")
    func realExportedBookmark() throws {
        // Not a hand-written fixture: this is a bookmark Cyberduck wrote, transcribed. It is the only
        // evidence that the mapping matches what the app actually produces rather than what its source
        // suggests it should.
        let host = try bookmark(DuckFixture.realSFTPBookmark)

        #expect(host.nickname == "fessior-dev")
        #expect(host.hostname == "61.28.226.131")
        #expect(host.port == 234, "a non-default port, written as a string")
        #expect(host.username == "stackops")
        #expect(host.id.uuidString.lowercased() == "d88bb6e5-2b5b-4c81-a4fa-9b1ecb474f21")
        #expect(host.defaultPath == nil, "Cyberduck omits Path when there is none")
        #expect(host.comment == nil)
        #expect(host.authenticationPreference == .password, "no key named, so nothing changes")
    }

    @Test("A real bookmark keeps the settings DriverPro has no field for")
    func realExportedBookmarkRoundTrips() throws {
        let host = try bookmark(DuckFixture.realSFTPBookmark)
        let parsed = try PropertyListSerialization.propertyList(from: DuckFormat.encode(host),
                                                               format: nil)
        let dictionary = try #require(parsed as? [String: Any])

        #expect(dictionary["Encoding"] as? String == "UTF-8")
        #expect(dictionary["Access Timestamp"] as? String == "1787163977250")
        #expect(dictionary["Provider"] as? String == "iterate GmbH")
        #expect(dictionary["Labels"] as? [String] == [], "an empty array is still theirs to keep")
        #expect(dictionary["Port"] as? String == "234")
    }

    @Test("Without a Protocol it is not a bookmark")
    func noProtocolIsUnreadable() {
        // A `.cyberduckprofile` shares this shape; importing one as a bookmark would be nonsense.
        let decoded = decode(DuckFixture.plist("<key>Hostname</key><string>example.com</string>"))
        guard case .unreadable = decoded else {
            Issue.record("expected unreadable, got \(decoded)")
            return
        }
    }

    @Test("An unknown protocol identifier is reported rather than guessed at")
    func unknownProtocolIsUnreadable() {
        let decoded = decode(DuckFixture.plist("""
            <key>Protocol</key><string>gopher</string>
            <key>Hostname</key><string>example.com</string>
            """))
        guard case .unreadable = decoded else {
            Issue.record("expected unreadable, got \(decoded)")
            return
        }
    }

    @Test("Junk is unreadable, not a crash")
    func junkIsUnreadable() {
        guard case .unreadable = decode(Data("not a plist at all".utf8)) else {
            Issue.record("expected unreadable")
            return
        }
    }
}

@Suite("DuckFormat — encoding")
struct DuckEncodingTests {

    private func encoded(_ host: RemoteHost) throws -> [String: Any] {
        let data = try DuckFormat.encode(host)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(parsed as? [String: Any])
    }

    private func makeHost() -> RemoteHost {
        RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 2222,
                   username: "duck", defaultPath: RemotePath("/srv"), nickname: "Work",
                   comment: "notes")
    }

    @Test("The port is written as a string")
    func portIsWrittenAsAString() throws {
        // The single easiest way to get this format wrong. Cyberduck reads Port with `stringForKey`,
        // so `<integer>2222</integer>` loads with the port silently ignored — asserted by *type*.
        let dictionary = try encoded(makeHost())

        #expect(dictionary["Port"] as? String == "2222")
        #expect(dictionary["Port"] as? Int == nil, "a number here is a file Cyberduck mis-reads")
    }

    @Test("Every field DriverPro models is written")
    func writesEveryField() throws {
        let dictionary = try encoded(makeHost())

        #expect(dictionary["Protocol"] as? String == "sftp")
        #expect(dictionary["Hostname"] as? String == "example.com")
        #expect(dictionary["Username"] as? String == "duck")
        #expect(dictionary["Path"] as? String == "/srv")
        #expect(dictionary["Nickname"] as? String == "Work")
        #expect(dictionary["Comment"] as? String == "notes")
        #expect(dictionary["UUID"] as? String != nil)
    }

    @Test("Fields with nothing in them are absent, not empty")
    func emptyFieldsAreOmitted() throws {
        // Cyberduck treats a missing key and an empty string differently: an empty Nickname shows as a
        // blank row in its sidebar.
        let bare = RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 22)
        let dictionary = try encoded(bare)

        #expect(dictionary["Nickname"] == nil)
        #expect(dictionary["Username"] == nil)
        #expect(dictionary["Comment"] == nil)
        #expect(dictionary["Private Key File"] == nil)
    }

    @Test("A key path is written in both spellings, abbreviated as Cyberduck writes it")
    func writesThePrivateKey() throws {
        var host = makeHost()
        let path = NSString(string: "~/.ssh/id_ed25519").expandingTildeInPath
        host.authenticationPreference = .privateKey(path: path)

        let dictionary = try encoded(host)
        let local = try #require(dictionary["Private Key File Dictionary"] as? [String: Any])

        #expect(local["Path"] as? String == "~/.ssh/id_ed25519", "abbreviated, as Local.serialize does")
        #expect(dictionary["Private Key File"] as? String == "~/.ssh/id_ed25519",
                "the legacy key too, for older Cyberduck builds")
    }

    @Test("WebDAV exports as the secure spelling")
    func webdavExportsAsDavs() throws {
        let host = RemoteHost(protocolIdentifier: .webdav, hostname: "cloud.example.com", port: 443)
        #expect(try encoded(host)["Protocol"] as? String == "davs")
    }

    // MARK: - One path in the file, two in the bookmark

    @Test("A WebDAV bookmark exports its DAV root as Path")
    func webdavExportsTheDavRootAsPath() throws {
        // Cyberduck has one path where DriverPro has two. `Path` carries the DAV root because it is the
        // half without which nothing resolves — and because a Nextcloud bookmark Cyberduck exported has
        // its DAV root there, so reading and writing agree.
        let host = RemoteHost(
            protocolIdentifier: .webdav, hostname: "cloud.example.com", port: 443, username: "duck",
            defaultPath: RemotePath("/Photos"),
            properties: [RemoteHost.webdavBasePathKey: "/remote.php/dav/files/duck"]
        )

        let dictionary = try encoded(host)

        #expect(dictionary["Path"] as? String == "/remote.php/dav/files/duck")
        #expect(dictionary["DriverPro Default Path"] as? String == "/Photos",
                "the folder to open goes somewhere Cyberduck will ignore rather than being dropped")
    }

    @Test("A WebDAV bookmark with no DAV root exports no Path at all")
    func webdavWithoutADavRootWritesNoPath() throws {
        // A plain server at the root is the ordinary case, and an empty string is not the same as a
        // missing key — Cyberduck treats them differently, which is why `setOrRemove` exists.
        let host = RemoteHost(protocolIdentifier: .webdav, hostname: "dav.example.com", port: 443)

        #expect(try encoded(host)["Path"] == nil)
    }

    @Test("SFTP's Path still means the folder to open")
    func sftpPathIsUnchanged() throws {
        // The WebDAV rule must not leak into the protocol that had this right already.
        let host = RemoteHost(
            protocolIdentifier: .sftp, hostname: "example.com", port: 22,
            defaultPath: RemotePath("/srv/www")
        )

        let dictionary = try encoded(host)

        #expect(dictionary["Path"] as? String == "/srv/www")
        #expect(dictionary["DriverPro Default Path"] == nil, "one path is all SFTP has")
    }

    @Test("The file is named the way Cyberduck names its own")
    func fileNaming() {
        let host = RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 22,
                              nickname: "Work – EU")
        #expect(DuckFormat.fileName(for: host) == "Work – EU.duck")

        // A nickname with a path separator in it must not write outside the chosen folder.
        let awkward = RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 22,
                                 nickname: "a/b:c")
        #expect(DuckFormat.fileName(for: awkward) == "a-b-c.duck")
    }
}

@Suite("DuckFormat — round trip")
struct DuckRoundTripTests {

    // MARK: - One path in the file, two in the bookmark

    @Test("A Nextcloud bookmark from Cyberduck imports with its DAV root, not a default path")
    func cyberduckWebdavPathIsTheDavRoot() throws {
        // What a real Cyberduck Nextcloud bookmark looks like: one Path, and it holds the DAV root.
        // Read as a default path — which is what DriverPro did before — the bookmark connects to the
        // server root and finds nothing.
        let file = DuckFixture.plist("""
            <key>Protocol</key><string>davs</string>
            <key>Hostname</key><string>cloud.example.com</string>
            <key>Port</key><string>443</string>
            <key>Username</key><string>duck</string>
            <key>Path</key><string>/remote.php/dav/files/duck</string>
            """)

        guard case .bookmark(let host) = DuckFormat.decode(file, supported: [.sftp, .webdav]) else {
            Issue.record("fixture did not decode")
            return
        }

        #expect(host.properties[RemoteHost.webdavBasePathKey] == "/remote.php/dav/files/duck")
        #expect(host.defaultPath == nil, "Cyberduck's Path is the root, not a folder inside it")
    }

    @Test("A WebDAV bookmark survives a round trip with both its paths")
    func webdavPathsRoundTrip() throws {
        let original = RemoteHost(
            protocolIdentifier: .webdav, hostname: "cloud.example.com", port: 443, username: "duck",
            defaultPath: RemotePath("/Photos"),
            properties: [RemoteHost.webdavBasePathKey: "/remote.php/dav/files/duck"]
        )

        guard case .bookmark(let returned) = DuckFormat.decode(try DuckFormat.encode(original),
                                                               supported: [.sftp, .webdav]) else {
            Issue.record("the file we wrote did not decode")
            return
        }

        #expect(returned.properties[RemoteHost.webdavBasePathKey] == "/remote.php/dav/files/duck")
        #expect(returned.defaultPath == RemotePath("/Photos"))
    }

    @Test("Settings DriverPro has no field for survive a round trip")
    func preservesUnmappedKeys() throws {
        // Import then export must not quietly destroy someone's timezone, labels or folder settings.
        guard case .bookmark(let host) = DuckFormat.decode(DuckFixture.sftp, supported: [.sftp]) else {
            Issue.record("fixture did not decode")
            return
        }

        let parsed = try PropertyListSerialization.propertyList(from: DuckFormat.encode(host),
                                                               format: nil)
        let dictionary = try #require(parsed as? [String: Any])

        #expect(dictionary["Timezone"] as? String == "Europe/Zurich")
        #expect(dictionary["Labels"] as? [String] == ["work", "eu"])
        #expect(dictionary["Provider"] as? String == "iterate GmbH")

        let workdir = try #require(dictionary["Workdir Dictionary"] as? [String: Any])
        #expect(workdir["Path"] as? String == "/srv", "nested values survive too")
    }

    @Test("The key file's Bookmark alias is kept, even though DriverPro cannot use it")
    func preservesTheSecurityScopedBookmark() throws {
        // Sandboxed Cyberduck needs it to reopen the key; DriverPro is not sandboxed and does not.
        // Dropping it would break their file for them.
        guard case .bookmark(let host) = DuckFormat.decode(DuckFixture.sftp, supported: [.sftp]) else {
            Issue.record("fixture did not decode")
            return
        }

        let parsed = try PropertyListSerialization.propertyList(from: DuckFormat.encode(host),
                                                               format: nil)
        let dictionary = try #require(parsed as? [String: Any])
        let local = try #require(dictionary["Private Key File Dictionary"] as? [String: Any])

        #expect(local["Bookmark"] as? String == "Ym9va21hcmtkYXRh")
    }

    @Test("A DriverPro bookmark survives a trip out and back")
    func bookmarkSurvivesBothWays() throws {
        var original = RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 2222,
                                  username: "duck", defaultPath: RemotePath("/srv"),
                                  nickname: "Work", comment: "notes")
        original.authenticationPreference = .privateKey(path: "/Users/duck/.ssh/id_ed25519")

        guard case .bookmark(let restored) = DuckFormat.decode(try DuckFormat.encode(original),
                                                              supported: [.sftp]) else {
            Issue.record("what we wrote, we cannot read")
            return
        }

        #expect(restored.id == original.id, "identity survives, so re-importing updates in place")
        #expect(restored.hostname == original.hostname)
        #expect(restored.port == original.port)
        #expect(restored.username == original.username)
        #expect(restored.defaultPath == original.defaultPath)
        #expect(restored.nickname == original.nickname)
        #expect(restored.comment == original.comment)
        #expect(restored.authenticationPreference == original.authenticationPreference)
    }
}

@Suite("BookmarkStore — .duck files")
struct DuckStoreTests {

    private func makeStore() throws -> BookmarkStore {
        BookmarkStore(database: try Database(.memory, migrations: BookmarkStore.migrations))
    }

    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-duck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A folder of mixed files imports the good ones and reports the rest")
    func importsAFolder() async throws {
        let store = try makeStore()
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        try DuckFixture.sftp.write(to: folder.appending(path: "work.duck"))
        try DuckFixture.plist("""
            <key>Protocol</key><string>davs</string>
            <key>Hostname</key><string>cloud.example.com</string>
            """).write(to: folder.appending(path: "cloud.duck"))
        try Data("junk".utf8).write(to: folder.appending(path: "broken.duck"))
        try Data("ignored".utf8).write(to: folder.appending(path: "notes.txt"))

        let summary = try await store.importDuck(from: [folder], supported: [.sftp])

        #expect(summary.imported == 1)
        #expect(summary.unsupported[.webdav] == 1)
        #expect(summary.unreadable == 1, "the .txt is not counted; it was never a candidate")
        #expect(try await store.load().count == 1)
    }

    @Test("Individual files can be imported, as a drop hands them over")
    func importsLooseFiles() async throws {
        let store = try makeStore()
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = folder.appending(path: "work.duck")
        try DuckFixture.sftp.write(to: file)

        let summary = try await store.importDuck(from: [file], supported: [.sftp])
        #expect(summary.imported == 1)
    }

    @Test("Importing the same file twice leaves one bookmark")
    func importIsIdempotent() async throws {
        // The UUID in the file is kept, and `save` upserts on it.
        let store = try makeStore()
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = folder.appending(path: "work.duck")
        try DuckFixture.sftp.write(to: file)

        try await store.importDuck(from: [file], supported: [.sftp])
        try await store.importDuck(from: [file], supported: [.sftp])

        #expect(try await store.load().count == 1)
    }

    @Test("Export writes one file per bookmark, and reads back")
    func exportsAndReimports() async throws {
        let store = try makeStore()
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        try await store.save(RemoteHost(protocolIdentifier: .sftp, hostname: "one.example.com",
                                        port: 22, username: "duck", nickname: "One"))
        try await store.save(RemoteHost(protocolIdentifier: .sftp, hostname: "two.example.com",
                                        port: 2222, username: "duck", nickname: "Two"))

        #expect(try await store.exportDuck(to: folder) == 2)

        let written = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(written.count == 2)
        #expect(written.allSatisfy { $0.pathExtension == "duck" })

        let fresh = try makeStore()
        let summary = try await fresh.importDuck(from: [folder], supported: [.sftp])
        #expect(summary.imported == 2)
        #expect(try await fresh.load().map(\.nickname) == ["One", "Two"])
    }

    @Test("One bookmark exports to one file, and reads back as itself")
    func exportsASingleBookmark() async throws {
        // What the sidebar's Export Bookmark… does: share one connection rather than back up all.
        let store = try makeStore()
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        var host = RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 2222,
                              username: "duck", nickname: "Work", comment: "notes")
        host.authenticationPreference = .privateKey(path: "/Users/duck/.ssh/id_ed25519")
        try await store.save(host)

        let file = folder.appending(path: DuckFormat.fileName(for: host))
        try await store.exportDuck(host, to: file)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let fresh = try makeStore()
        #expect(try await fresh.importDuck(from: [file], supported: [.sftp]).imported == 1)

        let restored = try #require(try await fresh.load().first)
        #expect(restored.id == host.id)
        #expect(restored.port == 2222)
        #expect(restored.authenticationPreference == host.authenticationPreference)
    }

    @Test("Exporting one bookmark carries no secret")
    func exportedBookmarkHasNoSecret() async throws {
        // The claim that makes a `.duck` safe to send someone: the schema has no field for a password,
        // and this is the check that keeps it true.
        let store = try makeStore()
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let host = RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 22,
                              username: "duck", nickname: "Work")
        let file = folder.appending(path: "work.duck")
        try await store.exportDuck(host, to: file)

        let written = try String(contentsOf: file, encoding: .utf8).lowercased()
        #expect(!written.contains("password"))
        #expect(!written.contains("passphrase"))
        #expect(!written.contains("secret"))
    }

    @Test("Two bookmarks with the same name do not overwrite each other")
    func exportNamesCollide() async throws {
        // The same server under two accounts is an ordinary thing to have.
        let store = try makeStore()
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        try await store.save(RemoteHost(protocolIdentifier: .sftp, hostname: "example.com",
                                        port: 22, username: "duck", nickname: "Work"))
        try await store.save(RemoteHost(protocolIdentifier: .sftp, hostname: "example.com",
                                        port: 22, username: "goose", nickname: "Work"))

        try await store.exportDuck(to: folder)
        let written = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(written.count == 2, "the second must not land on top of the first")
    }
}
