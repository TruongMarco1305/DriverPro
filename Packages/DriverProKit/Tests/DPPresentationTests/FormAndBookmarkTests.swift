//
//  FormAndBookmarkTests.swift
//  DPPresentationTests
//

import DPBookmarks
import DPCore
import DPCredentials
import DPDatabase
import DPServices
import Foundation
import Testing
@testable import DPPresentation

@Suite("ConnectionFormModel")
@MainActor
struct ConnectionFormModelTests {

    @Test("The port starts at the protocol's default")
    func portDefaultsFromDescriptor() {
        let form = ConnectionFormModel()
        #expect(form.protocolIdentifier == .sftp)
        #expect(form.port == "22")
    }

    @Test("Choosing a protocol resets the port to that protocol's default")
    func choosingAProtocolResetsThePort() {
        // The chooser step relies on this: pick SFTP, then go back and pick WebDAV, and the port must
        // follow rather than leaving 22 in a WebDAV form.
        let catalog = ProtocolCatalog(descriptors: [
            ProtocolDescriptor(id: .sftp, displayName: "SFTP", summary: "Over SSH.", scheme: "sftp",
                               defaultPort: 22, fields: [.username, .password], iconName: "server.rack"),
            ProtocolDescriptor(id: .webdav, displayName: "WebDAV", summary: "Over HTTPS.", scheme: "https",
                               defaultPort: 443, fields: [.username, .password], iconName: "globe")
        ])
        let form = ConnectionFormModel(catalog: catalog)
        #expect(form.port == "22")

        form.port = "2222"
        form.protocolIdentifier = .webdav
        #expect(form.port == "443", "a typed port belongs to the protocol it was typed for")
    }

    @Test("Which fields to show comes from the descriptor, not from a switch in a view")
    func fieldsComeFromDescriptor() {
        // The claim that adding WebDAV needs no view change is only true if the view asks this.
        let form = ConnectionFormModel()
        #expect(form.shows(.username))
        #expect(form.shows(.password))
        #expect(form.shows(.privateKey))
        #expect(!form.shows(.anonymous), "SFTP has no anonymous mode")
    }

    @Test("A hostname is required, and the port must be a real port", arguments: [
        (hostname: "", port: "22", valid: false),
        (hostname: "   ", port: "22", valid: false),
        (hostname: "example.com", port: "22", valid: true),
        (hostname: "example.com", port: "", valid: false),
        (hostname: "example.com", port: "abc", valid: false),
        (hostname: "example.com", port: "0", valid: false),
        (hostname: "example.com", port: "70000", valid: false),
        (hostname: "example.com", port: "2222", valid: true)
    ])
    func validation(_ testCase: (hostname: String, port: String, valid: Bool)) {
        let form = ConnectionFormModel()
        form.hostname = testCase.hostname
        form.port = testCase.port
        form.password = "hunter2"      // required; varied separately below
        #expect(form.isValid == testCase.valid)
    }

    @Test("A password is required, because this sheet only creates new connections")
    func passwordIsRequired() {
        // Reconnecting to a saved bookmark never opens this sheet, so there is nothing in the Keychain
        // to fall back on and a blank password would just fail at the server.
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        #expect(!form.isValid)

        form.password = "hunter2"
        #expect(form.isValid)
    }

    @Test("Credentials are always saved to the Keychain")
    func credentialsAlwaysPersist() {
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.username = "duck"
        form.password = "hunter2"

        #expect(form.makeCredentials()?.shouldPersist == true)
    }

    @Test("The description is stored on the bookmark and read back")
    func descriptionRoundTrips() throws {
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.password = "hunter2"
        form.nickname = "Work"
        form.details = "  Staging box, EU  "

        let host = try #require(form.makeHost())
        #expect(host.comment == "Staging box, EU", "whitespace trimmed like the other fields")

        let reloaded = ConnectionFormModel()
        reloaded.load(from: host)
        #expect(reloaded.details == "Staging box, EU")
    }

    @Test("An empty description stays absent rather than becoming a blank string")
    func emptyDescriptionIsNil() throws {
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.password = "hunter2"
        form.details = "   "

        #expect(try #require(form.makeHost()).comment == nil)
    }

    @Test("The built bookmark trims whitespace and drops empty optionals")
    func buildsAHost() throws {
        let form = ConnectionFormModel()
        form.hostname = "  example.com  "
        form.port = "2222"
        form.username = " duck "
        form.password = "hunter2"
        form.nickname = ""
        form.defaultPath = "  "

        let host = try #require(form.makeHost())
        #expect(host.hostname == "example.com")
        #expect(host.port == 2222)
        #expect(host.username == "duck")
        // Empty is not the same as blank: "no nickname recorded" must stay distinguishable.
        #expect(host.nickname == nil)
        #expect(host.defaultPath == nil)
    }

    @Test("An invalid form builds nothing")
    func invalidFormBuildsNothing() {
        let form = ConnectionFormModel()
        form.hostname = ""
        #expect(form.makeHost() == nil)
    }

    @Test("Loading a bookmark fills the form but never the password")
    func loadsFromBookmark() {
        let host = RemoteHost(
            protocolIdentifier: .sftp, hostname: "example.com", port: 2222, username: "duck",
            defaultPath: RemotePath("/srv"), nickname: "Work", comment: "notes"
        )
        let form = ConnectionFormModel()
        form.password = "left over from before"
        form.load(from: host)

        #expect(form.hostname == "example.com")
        #expect(form.port == "2222")
        #expect(form.username == "duck")
        #expect(form.defaultPath == "/srv")
        #expect(form.nickname == "Work")
        #expect(form.password.isEmpty, "a stored password is never loaded back into a text field")
    }

    // MARK: - WebDAV

    @Test("WebDAV offers only a password, because that is all it has")
    func webdavOffersOnlyPassword() {
        // The picker reads the descriptor rather than listing SFTP's methods for every protocol. Adding
        // a backend with different authentication should need no view change at all.
        let form = ConnectionFormModel()
        form.protocolIdentifier = .webdav

        #expect(form.offeredAuthentications == [.password])
        #expect(form.shows(.basePath), "the DAV root is asked for")
        #expect(!form.shows(.privateKey), "and keys are not")
    }

    @Test("Choosing WebDAV moves the port to 443")
    func webdavDefaultsToHTTPS() {
        let form = ConnectionFormModel()
        form.protocolIdentifier = .webdav
        #expect(form.port == "443")
    }

    @Test("The DAV root round-trips through the bookmark")
    func basePathRoundTrips() throws {
        // The whole Nextcloud story: a vendor's layout is a property on the bookmark, not a branch in
        // the code.
        let form = ConnectionFormModel()
        form.protocolIdentifier = .webdav
        form.hostname = "cloud.example.com"
        form.username = "duck"
        form.password = "hunter2"
        form.basePath = "  /remote.php/dav/files/duck  "

        let host = try #require(form.makeHost())
        #expect(host.properties[RemoteHost.webdavBasePathKey] == "/remote.php/dav/files/duck",
                "trimmed like every other field")

        let reloaded = ConnectionFormModel()
        reloaded.load(from: host)
        #expect(reloaded.basePath == "/remote.php/dav/files/duck")
    }

    @Test("A blank DAV root is not a valid WebDAV bookmark")
    func blankBasePathIsRejected() {
        // It used to mean "the server root", which is right for a plain server and catastrophic for a
        // Nextcloud: that publishes files at /remote.php/dav/files/<user> and serves its *web
        // interface* at `/`, so a blank field reached a real server that answered and did not speak
        // WebDAV. The refusal named a field the user believed they had already set.
        //
        // The root is now something chosen rather than defaulted into. `/` still means the server root.
        let form = ConnectionFormModel()
        form.protocolIdentifier = .webdav
        form.hostname = "dav.example.com"
        form.password = "hunter2"
        form.basePath = "   "

        #expect(!form.isValid, "Connect stays disabled until the DAV root is answered")
        #expect(form.makeHost() == nil)
    }

    @Test("A DAV root of / means the server root, and no property")
    func slashBasePathIsTheServerRoot() throws {
        // How a plain server is spelled now. `WebDAVPaths` trims the slashes off either end, so `/`
        // normalises to an empty prefix — the same URL as before, arrived at deliberately.
        let form = ConnectionFormModel()
        form.protocolIdentifier = .webdav
        form.hostname = "dav.example.com"
        form.password = "hunter2"
        form.basePath = "/"

        #expect(form.isValid)
        let host = try #require(form.makeHost())
        #expect(host.properties[RemoteHost.webdavBasePathKey] == "/")

        // And it survives a reload, so the field does not silently empty itself on an edit.
        let reloaded = ConnectionFormModel()
        reloaded.load(from: host)
        #expect(reloaded.basePath == "/")
        #expect(reloaded.isValid)
    }

    @Test("Clearing the DAV root on an edit blocks the save rather than dropping it")
    func clearingBasePathBlocksTheSave() {
        var host = RemoteHost(protocolIdentifier: .webdav, hostname: "cloud.example.com", port: 443,
                              username: "duck")
        host.properties[RemoteHost.webdavBasePathKey] = "/remote.php/dav/files/duck"

        let form = ConnectionFormModel()
        form.load(from: host)
        form.basePath = ""

        // Emptying the field is how the bookmark used to break, so it must not be a saveable state.
        #expect(!form.isValid)
        #expect(form.makeHost() == nil)
    }

    @Test("The DAV root is required only where it is asked for")
    func otherProtocolsAreUnaffected() {
        // SFTP has no DAV root and no field for one. Requiring a value it never collects would make
        // every SFTP bookmark unsaveable.
        let form = ConnectionFormModel()
        form.protocolIdentifier = .sftp
        form.hostname = "example.com"
        form.username = "duck"
        form.password = "hunter2"

        #expect(!form.shows(.basePath))
        #expect(form.isValid)
    }

    @Test("Editing a WebDAV bookmark keeps properties it does not know about")
    func editingKeepsForeignProperties() throws {
        // `duck.unmapped` from a Cyberduck import, for instance. Rebuilding `properties` from the form
        // would silently drop it.
        var host = RemoteHost(protocolIdentifier: .webdav, hostname: "cloud.example.com", port: 443,
                              username: "duck")
        host.properties["duck.unmapped"] = "opaque"

        let form = ConnectionFormModel()
        form.load(from: host)
        form.basePath = "/dav"

        let saved = try #require(form.makeHost())
        #expect(saved.properties["duck.unmapped"] == "opaque")
        #expect(saved.properties[RemoteHost.webdavBasePathKey] == "/dav")
    }

    // MARK: - Editing

    @Test("Editing keeps the bookmark's identity, so a save updates rather than duplicates")
    func editingKeepsTheIdentity() async throws {
        let original = RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 22,
                                  username: "duck", nickname: "Work")
        let store = BookmarkStore(database: try Database(.memory, migrations: BookmarkStore.migrations))
        try await store.save(original)

        let form = ConnectionFormModel()
        form.load(from: original)
        #expect(form.isEditing)

        form.nickname = "Work (EU)"
        let edited = try #require(form.makeHost())
        #expect(edited.id == original.id)

        try await store.save(edited)
        let saved = try await store.load()
        #expect(saved.count == 1, "an edit must not leave the old row behind")
        #expect(saved.first?.nickname == "Work (EU)")
    }

    @Test("Editing a bookmark keeps protocol settings the form does not know about")
    func editingPreservesUnknownProperties() throws {
        // The form has no field for these and never will. Rebuilding the bookmark from its fields
        // alone would delete them, so an S3 bookmark would lose its region every time somebody
        // renamed it.
        let original = RemoteHost(
            protocolIdentifier: .sftp, hostname: "example.com", port: 22, username: "duck",
            properties: ["s3.region": "eu-west-1", "sftp.privateKeyPath": "/Users/duck/.ssh/id_ed25519"]
        )
        let form = ConnectionFormModel()
        form.load(from: original)
        form.nickname = "Work (EU)"

        let edited = try #require(form.makeHost())

        // Every key the form does not understand survives untouched. It may *add* to the bag — the login
        // method lives there too — but it must never drop anything.
        for (key, value) in original.properties {
            #expect(edited.properties[key] == value, "\(key) was lost")
        }
    }

    @Test("A bookmark the form created carries no settings it was never given")
    func creatingStartsWithNoBorrowedProperties() throws {
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.password = "hunter2"

        // Only what this form actually chose. A fresh bookmark inheriting another's region or key path
        // would be a data-leak between connections.
        let properties = try #require(form.makeHost()).properties
        #expect(properties == [RemoteHost.authenticationMethodKey: AuthenticationKind.password.rawValue])
    }

    @Test("A blank password is fine when editing, because the saved one is being kept")
    func editingDoesNotRequireThePassword() {
        // The Keychain never reads a password back into a text field, so demanding one here would mean
        // retyping it to change a nickname.
        let host = RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 22,
                              username: "duck")
        let form = ConnectionFormModel()
        form.load(from: host)

        #expect(form.password.isEmpty)
        #expect(form.isValid)
        #expect(form.makeCredentials() == nil, "nothing typed means nothing to hand over")

        form.password = "new one"
        #expect(form.makeCredentials()?.shouldPersist == true)
    }

    @Test("A form that was never loaded still mints a fresh identity each time")
    func creatingMintsNewIdentities() throws {
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.password = "hunter2"

        #expect(!form.isEditing)
        #expect(try #require(form.makeHost()).id != #require(form.makeHost()).id)
    }

    // MARK: - Authentication

    @Test("A new form starts on a password, and offers what the protocol accepts")
    func authenticationDefaults() {
        let form = ConnectionFormModel()
        #expect(form.authentication == .password)
        #expect(form.offeredAuthentications == [.password, .privateKey, .agent])
    }

    @Test("A key login needs a key, not a password")
    func keyLoginRequiresAKey() {
        // The asymmetry with a password is deliberate: a blank password can fall back to the Keychain, but
        // a bookmark saying "use a key" without naming one would quietly become a password login.
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.authentication = .privateKey

        #expect(!form.isValid, "no key chosen")
        form.privateKeyPath = "/Users/duck/.ssh/id_ed25519"
        #expect(form.isValid, "and no password needed")
        #expect(form.makeCredentials() == nil, "key material is not a form's business")
    }

    @Test("An agent login needs nothing typed at all")
    func agentLoginNeedsNothing() {
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.authentication = .agent

        #expect(form.isValid)
        #expect(form.makeCredentials() == nil)
    }

    @Test("A typed password is ignored once another method is chosen")
    func passwordIsNotOfferedForOtherMethods() {
        // Otherwise switching to a key after typing a password would preload it and connect with the
        // password instead, which looks like the picker did nothing.
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.password = "hunter2"
        #expect(form.makeCredentials() != nil)

        form.authentication = .agent
        #expect(form.makeCredentials() == nil)
    }

    @Test("The login choice round-trips through a bookmark", arguments: [
        AuthenticationKind.password, .privateKey, .agent
    ])
    func authenticationRoundTrips(kind: AuthenticationKind) throws {
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.password = "hunter2"
        form.authentication = kind
        form.privateKeyPath = "/Users/duck/.ssh/id_ed25519"

        let host = try #require(form.makeHost())

        let reloaded = ConnectionFormModel()
        reloaded.load(from: host)
        #expect(reloaded.authentication == kind)
        if kind == .privateKey {
            #expect(reloaded.privateKeyPath == "/Users/duck/.ssh/id_ed25519")
        }
    }

    @Test("A key path survives an edit that switches to a password and back")
    func keyPathSurvivesSwitchingAway() throws {
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.authentication = .privateKey
        form.privateKeyPath = "/Users/duck/.ssh/id_ed25519"
        let host = try #require(form.makeHost())

        let editing = ConnectionFormModel()
        editing.load(from: host)
        editing.authentication = .password
        editing.password = "hunter2"
        let saved = try #require(editing.makeHost())

        // Still on the bookmark, so switching back does not mean finding the file again.
        let again = ConnectionFormModel()
        again.load(from: saved)
        again.authentication = .privateKey
        #expect(again.privateKeyPath == "/Users/duck/.ssh/id_ed25519")
    }

    @Test("Discovering keys finds what is in the directory and reports no agent when there is none")
    func discoversKeysAndNoAgent() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try openSSHKeyText().write(to: directory.appending(path: "id_ed25519"),
                                   atomically: true, encoding: .utf8)

        let form = ConnectionFormModel()
        form.discoverKeys(locator: PrivateKeyLocator(sshDirectory: directory), agent: nil)

        #expect(form.discoveredKeys.map(\.name) == ["id_ed25519"])
        #expect(form.agentIdentities == nil, "no agent and an empty agent must be distinguishable")
    }

    @Test("Choosing a key file selects it and switches the method")
    func choosingAKeyFileSelectsIt() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "work-server.key")
        try openSSHKeyText().write(to: url, atomically: true, encoding: .utf8)

        let form = ConnectionFormModel()
        form.choosePrivateKey(at: url)

        #expect(form.authentication == .privateKey)
        #expect(form.privateKeyPath == url.path)
        #expect(form.privateKeyName == "work-server.key", "the row shows the file, not the whole path")
        #expect(form.privateKeyStatus == .usable(try PrivateKeyLocator().inspectKey(at: url)))
    }

    // MARK: - Checking the chosen key

    @Test("Choosing the .pub file is refused, and the form will not submit")
    func choosingAPublicKeyIsRefused() throws {
        // The mistake this validation exists for: `id_ed25519` and `id_ed25519.pub` sit side by side. It
        // used to be accepted silently and surface much later as a login failure that never mentioned the
        // file.
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "id_ed25519.pub")
        try "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 duck@example.com"
            .write(to: url, atomically: true, encoding: .utf8)

        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.choosePrivateKey(at: url)

        guard case .rejected(let reason) = form.privateKeyStatus else {
            Issue.record("expected a rejection, got \(form.privateKeyStatus)")
            return
        }
        #expect(reason.contains("private half"), "and it should say what to pick instead")
        #expect(!form.isValid, "Connect must be disabled while the wrong file is chosen")
    }

    @Test("Choosing a file that is not a key at all is refused")
    func choosingSomethingElseIsRefused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "notes.txt")
        try "shopping list".write(to: url, atomically: true, encoding: .utf8)

        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.choosePrivateKey(at: url)

        guard case .rejected = form.privateKeyStatus else {
            Issue.record("expected a rejection, got \(form.privateKeyStatus)")
            return
        }
        #expect(!form.isValid)
    }

    @Test("Choosing a good key clears an earlier rejection")
    func choosingAGoodKeyRecovers() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bad = directory.appending(path: "notes.txt")
        try "shopping list".write(to: bad, atomically: true, encoding: .utf8)
        let good = directory.appending(path: "id_ed25519")
        try openSSHKeyText().write(to: good, atomically: true, encoding: .utf8)

        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.choosePrivateKey(at: bad)
        #expect(!form.isValid)

        form.choosePrivateKey(at: good)
        #expect(form.isValid, "the error must not outlive the file that caused it")
    }

    @Test("An algorithm this transport cannot sign for is a warning, not a refusal")
    func anUnsupportedAlgorithmStillSubmits() throws {
        // ADR 014: an RSA key is offered anyway, because it does work against an older server. Pinned here
        // so a later tidy-up of the validation does not quietly reverse that decision.
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "id_rsa")
        try openSSHKeyText(algorithm: "ssh-rsa").write(to: url, atomically: true, encoding: .utf8)

        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.choosePrivateKey(at: url)

        guard case .usable(let key) = form.privateKeyStatus else {
            Issue.record("an RSA key is usable, just discouraged — got \(form.privateKeyStatus)")
            return
        }
        guard case .unsupported = key.supportLevel else {
            Issue.record("expected the RSA warning, got \(key.supportLevel)")
            return
        }
        #expect(form.isValid, "warned, not blocked")
    }

    @Test("A bookmark whose key file has gone says so when the sheet opens")
    func aMissingKeyIsCaughtOnDiscovery() throws {
        // Validation runs in `discoverKeys`, not `load(from:)`, because the latter runs inside the sheet's
        // initialiser. This is what that buys: the sheet reports a deleted key instead of the connection
        // failing later with nothing about the file.
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var host = RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 22, username: "duck")
        host.authenticationPreference = .privateKey(path: directory.appending(path: "gone").path)

        let form = ConnectionFormModel()
        form.load(from: host)
        #expect(form.isValid, "not looked at yet, so nothing to object to")

        form.discoverKeys(locator: PrivateKeyLocator(sshDirectory: directory), agent: nil)

        guard case .rejected = form.privateKeyStatus else {
            Issue.record("expected a rejection, got \(form.privateKeyStatus)")
            return
        }
        #expect(!form.isValid)
    }

    @Test("A new connection starts on the strongest key already in ~/.ssh")
    func discoveryOffersADefaultKey() throws {
        // What replaces the list the key row used to show. Only a default: it never overrides a choice.
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try openSSHKeyText().write(to: directory.appending(path: "id_ed25519"),
                                   atomically: true, encoding: .utf8)
        try openSSHKeyText(algorithm: "ssh-rsa").write(to: directory.appending(path: "id_rsa"),
                                                       atomically: true, encoding: .utf8)

        let form = ConnectionFormModel()
        form.discoverKeys(locator: PrivateKeyLocator(sshDirectory: directory), agent: nil)

        #expect(form.privateKeyName == "id_ed25519", "Ed25519 before RSA, as `conventionalNames` orders them")
    }

    @Test("Discovery does not overwrite a key the bookmark already names")
    func discoveryLeavesAChosenKeyAlone() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try openSSHKeyText().write(to: directory.appending(path: "id_ed25519"),
                                   atomically: true, encoding: .utf8)
        let chosen = directory.appending(path: "work-server.key")
        try openSSHKeyText().write(to: chosen, atomically: true, encoding: .utf8)

        let form = ConnectionFormModel()
        form.choosePrivateKey(at: chosen)
        form.discoverKeys(locator: PrivateKeyLocator(sshDirectory: directory), agent: nil)

        #expect(form.privateKeyPath == chosen.path)
    }

    // MARK: - Key fixtures

    /// A throwaway directory to write key files into.
    private func makeDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "dp-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A minimal but genuinely parseable OpenSSH key.
    ///
    /// Built rather than pasted, so the parts the code actually reads are visible: the magic string, the
    /// cipher name (`none` — not encrypted), two more empty strings, a key count, and the public half,
    /// whose leading algorithm name is what `supportLevel` keys off.
    ///
    /// - Parameter algorithm: The algorithm to claim, so an unsupported one can be exercised.
    private func openSSHKeyText(algorithm: String = "ssh-ed25519") -> String {
        func sshString(_ bytes: Data) -> Data {
            var out = Data([UInt8(bytes.count >> 24), UInt8(bytes.count >> 16),
                            UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)])
            out.append(bytes)
            return out
        }

        var body = Data("openssh-key-v1\0".utf8)
        body += sshString(Data("none".utf8))            // ciphername: not encrypted
        body += sshString(Data())                       // kdfname
        body += sshString(Data())                       // kdfoptions
        body += Data([0, 0, 0, 1])                      // one key
        body += sshString(sshString(Data(algorithm.utf8)) + sshString(Data(repeating: 7, count: 32)))

        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(body.base64EncodedString())
        -----END OPENSSH PRIVATE KEY-----
        """
    }

    // MARK: - Persistence

    @Test("The built bookmark survives a round trip through the store")
    func roundTripsThroughTheStore() async throws {
        let form = ConnectionFormModel()
        form.hostname = "example.com"
        form.port = "2222"
        form.username = "duck"
        form.password = "hunter2"
        form.nickname = "Work"

        let host = try #require(form.makeHost())
        let store = BookmarkStore(database: try Database(.memory, migrations: BookmarkStore.migrations))
        try await store.save(host)

        #expect(try await store.load().first == host)
    }
}

@Suite("BookmarkListModel")
@MainActor
struct BookmarkListModelTests {

    private func makeModel() throws -> BookmarkListModel {
        BookmarkListModel(store: BookmarkStore(
            database: try Database(.memory, migrations: BookmarkStore.migrations)
        ))
    }

    private func makeHost(_ nickname: String) -> RemoteHost {
        RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 22,
                   username: "duck", nickname: nickname)
    }

    @Test("An empty store shows nothing and reports no error")
    func startsEmpty() async throws {
        let model = try makeModel()
        await model.reload()
        #expect(model.bookmarks.isEmpty)
        #expect(model.errorMessage == nil)
    }

    @Test("Saving shows up in the list, sorted")
    func savingAppears() async throws {
        let model = try makeModel()
        await model.save(makeHost("Zebra"))
        await model.save(makeHost("apple"))

        #expect(model.bookmarks.map(\.nickname) == ["apple", "Zebra"])
    }

    @Test("Deleting removes one and keeps the rest")
    func deletingRemovesOne() async throws {
        let model = try makeModel()
        let keep = makeHost("Keep")
        let drop = makeHost("Drop")
        await model.save(keep)
        await model.save(drop)

        await model.delete(drop.id)
        #expect(model.bookmarks.map(\.nickname) == ["Keep"])
    }

    @Test("Deleting something absent is not an error")
    func deletingAbsentIsFine() async throws {
        let model = try makeModel()
        await model.delete(UUID())
        #expect(model.errorMessage == nil)
    }
}
