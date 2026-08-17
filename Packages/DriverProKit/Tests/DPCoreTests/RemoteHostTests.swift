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
}
