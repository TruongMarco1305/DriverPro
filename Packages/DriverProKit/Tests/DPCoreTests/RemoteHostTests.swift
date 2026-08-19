//
//  RemoteHostTests.swift
//  DPCoreTests
//

import Foundation
import Testing
@testable import DPCore

@Suite("RemoteHost")
struct RemoteHostTests {

    private func makeHost(username: String? = nil, nickname: String? = nil) -> RemoteHost {
        RemoteHost(protocolIdentifier: .sftp, hostname: "10.0.0.4", port: 22,
                   username: username, nickname: nickname)
    }

    // MARK: - Naming

    @Test("The nickname wins, then the user name, and the address only as a last resort")
    func displayNameFallsBack() {
        #expect(makeHost(username: "duck", nickname: "Work").displayName == "Work")
        #expect(makeHost(username: "duck").displayName == "duck")
        #expect(makeHost().displayName == "10.0.0.4")
    }

    @Test("An empty nickname is treated as no nickname")
    func emptyNicknameIsIgnored() {
        // Bookmarks written before nicknames were trimmed may hold "" rather than nil.
        #expect(makeHost(username: "duck", nickname: "").displayName == "duck")
    }

    @Test("The subtitle adds the user name, but never repeats the title")
    func subtitleOnlyAddsSomething() {
        #expect(makeHost(username: "duck", nickname: "Work").subtitle == "duck")
        #expect(makeHost(username: "duck").subtitle == nil, "the title is already the user name")
        #expect(makeHost(nickname: "Work").subtitle == nil, "nothing left to say")
        #expect(makeHost().subtitle == nil)
    }

    // MARK: - Keychain addressing

    @Test("The Keychain key is the protocol, host and port, with the user as the account")
    func keychainAddressing() {
        // Not derived from displayName: renaming a bookmark must not lose its password.
        let host = makeHost(username: "duck", nickname: "Work")
        #expect(host.keychainService == "sftp://10.0.0.4:22")
        #expect(host.keychainAccount == "duck")
        #expect(makeHost().keychainAccount == "", "anonymous connections still need a key")
    }

    // MARK: - Authentication preference

    @Test("A bookmark that says nothing about authentication means password")
    func authenticationDefaultsToPassword() {
        #expect(makeHost().authenticationPreference == .password)
    }

    @Test("The authentication preference round-trips through the property bag", arguments: [
        AuthenticationPreference.password,
        .privateKey(path: "/Users/duck/.ssh/id_ed25519"),
        .agent
    ])
    func preferenceRoundTrips(preference: AuthenticationPreference) throws {
        var host = makeHost(username: "duck")
        host.authenticationPreference = preference
        #expect(host.authenticationPreference == preference)

        // Through `Codable` too: the whole point of storing it in `properties` is that a bookmark
        // carrying it needs no schema change to be saved.
        let decoded = try JSONDecoder().decode(RemoteHost.self, from: JSONEncoder().encode(host))
        #expect(decoded.authenticationPreference == preference)
    }

    @Test("An unrecognised stored method degrades to password rather than trapping")
    func unknownMethodDegrades() {
        // A bookmark written by a newer version, hand-edited, or imported. Asking for a password is
        // recoverable; refusing to load the bookmark is not.
        var host = makeHost(username: "duck")
        host.properties[RemoteHost.authenticationMethodKey] = "kerberos"
        #expect(host.authenticationPreference == .password)
    }

    @Test("Choosing public key without a key on record is not public key")
    func privateKeyNeedsAPath() {
        var host = makeHost(username: "duck")
        host.properties[RemoteHost.authenticationMethodKey] = AuthenticationKind.privateKey.rawValue
        #expect(host.authenticationPreference == .password, "no path means there is nothing to offer")
    }

    @Test("Switching away from public key and back keeps the key path")
    func switchingMethodKeepsTheKeyPath() {
        // Retyping a path to try a password once would be a poor trade for the tidiness of clearing it.
        var host = makeHost(username: "duck")
        host.authenticationPreference = .privateKey(path: "/Users/duck/.ssh/id_ed25519")
        host.authenticationPreference = .password
        #expect(host.properties[RemoteHost.privateKeyPathKey] == "/Users/duck/.ssh/id_ed25519")

        host.authenticationPreference = .privateKey(path: "/Users/duck/.ssh/id_ed25519")
        #expect(host.authenticationPreference == .privateKey(path: "/Users/duck/.ssh/id_ed25519"))
    }
}

@Suite("Credentials")
struct CredentialsTests {

    @Test("No description leaks a secret, whatever the method", arguments: [
        Credentials.Method.password("hunter2"),
        .privateKey(data: Data("KEYBYTES".utf8), passphrase: "hunter2", path: "/tmp/k"),
        .token("hunter2"),
        .sshAgent,
        .anonymous
    ])
    func descriptionsAreRedacted(method: Credentials.Method) {
        let credentials = Credentials(username: "duck", method: method)
        #expect(!credentials.description.contains("hunter2"))
        #expect(!credentials.debugDescription.contains("hunter2"))
        #expect(!credentials.description.contains("KEYBYTES"))
    }

    @Test("A private key's path is printed, because it is not a secret and it is the useful half")
    func keyPathIsVisible() {
        let credentials = Credentials.privateKey(
            username: "duck", data: Data(), passphrase: "hunter2", path: "/tmp/id_ed25519")
        #expect(credentials.description.contains("/tmp/id_ed25519"))
        #expect(credentials.description.contains("+passphrase"))
    }

    @Test("An agent credential has nothing to persist")
    func agentPersistsNothing() {
        #expect(Credentials.sshAgent(username: "duck").shouldPersist == false)
    }
}

@Suite("RemoteItem")
struct RemoteItemTests {

    @Test("A directory has no size, whatever the server said")
    func directoriesHaveNoSize() {
        // SFTP reports a folder's own inode — 4 KB on a typical Linux server. True, useless, and read
        // by everyone as the size of the contents.
        let directory = RemoteItem(path: RemotePath("/srv/photos"), kind: .directory, size: 4_096)
        #expect(directory.size == nil)

        let file = RemoteItem(path: RemotePath("/srv/a.txt"), kind: .file, size: 4_096)
        #expect(file.size == 4_096, "files keep theirs")
    }

    @Test("A symbolic link keeps its size")
    func linksKeepTheirSize() {
        // A link's size is the length of its target path, which is real data about the link itself.
        let link = RemoteItem(path: RemotePath("/srv/link"), kind: .symbolicLink(target: nil), size: 11)
        #expect(link.size == 11)
    }
}
