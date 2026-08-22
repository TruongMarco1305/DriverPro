//
//  SessionPoolTests.swift
//  DPTransferTests
//

import DPCore
import DPTestSupport
import Foundation
import Testing
@testable import DPTransfer

@Suite("SessionPool")
struct SessionPoolTests {

    @Test("Sequential borrows reuse one connection instead of reconnecting")
    func reusesConnections() async throws {
        // The reason the pool exists. An SSH handshake costs far more than a small file, so a queue of
        // 200 files must not open 200 connections.
        let session = try await TransferFixture.makeSession()
        let factory = CountingSessionFactory(session: session)
        let pool = SessionPool(factory: factory, delegate: ScriptedDelegate())

        for _ in 0..<10 {
            try await pool.withSession(for: TransferFixture.host) { session in
                _ = try await session.list(.root)
            }
        }

        #expect(factory.created == 1)
    }

    @Test("Concurrent borrows never exceed the per-host limit")
    func respectsConcurrencyLimit() async throws {
        let session = try await TransferFixture.makeSession()
        let factory = CountingSessionFactory(session: session)
        let pool = SessionPool(factory: factory, delegate: ScriptedDelegate(), maxConnectionsPerHost: 3)
        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try? await pool.withSession(for: TransferFixture.host) { _ in
                        await tracker.enter()
                        // Long enough that borrowers genuinely overlap.
                        try? await Task.sleep(for: .milliseconds(20))
                        await tracker.leave()
                    }
                }
            }
        }

        #expect(await tracker.peak <= 3, "the pool handed out more connections than its limit")
        #expect(await tracker.peak > 1, "nothing ran concurrently, so the limit was not exercised")
    }

    @Test("A borrower blocked at the limit is eventually served")
    func waitersAreResumed() async throws {
        // The failure this guards against is a lost continuation: a queue that stalls forever with
        // workers waiting on a slot that was never handed back.
        let session = try await TransferFixture.makeSession()
        let pool = TransferFixture.makePool(session: session, maxConnectionsPerHost: 1)
        let counter = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try? await pool.withSession(for: TransferFixture.host) { _ in
                        await counter.enter()
                        await counter.leave()
                    }
                }
            }
        }

        #expect(await counter.completed == 5)
        #expect(await counter.peak == 1)
    }

    @Test("A thrown error still returns the connection")
    func errorsDoNotLeakSlots() async throws {
        // If a failure leaked its slot, a directory full of unreadable files would stall the queue
        // permanently once the limit was reached.
        let session = try await TransferFixture.makeSession()
        let pool = TransferFixture.makePool(session: session, maxConnectionsPerHost: 1)

        for _ in 0..<5 {
            await #expect(throws: SessionError.self) {
                try await pool.withSession(for: TransferFixture.host) { session in
                    _ = try await session.list(RemotePath("/does-not-exist"))
                }
            }
        }

        // A slot is still available, so this returns rather than hanging.
        try await pool.withSession(for: TransferFixture.host) { session in
            _ = try await session.list(.root)
        }
    }

    @Test("Editing a bookmark's settings does not reuse the old connection")
    func editedSettingsAreNotReused() async throws {
        // The pool is keyed by bookmark id, but a bookmark is editable. Change the port, the user name
        // or a WebDAV DAV root and the same id now means a different server — so a reused connection
        // would keep talking to the old address while the sidebar showed the new one. Silent, and
        // exactly the sort of thing someone hits while getting a Nextcloud's DAV root right.
        let factory = PerHostSessionFactory()
        let pool = SessionPool(factory: factory, delegate: ScriptedDelegate())

        var host = RemoteHost(protocolIdentifier: .webdav, hostname: "cloud.example.com", port: 443,
                              username: "duck")
        try await pool.withSession(for: host) { _ in }
        #expect(factory.created == 1)

        // The same bookmark, now with the DAV root it was missing.
        host.properties[RemoteHost.webdavBasePathKey] = "/remote.php/dav/files/duck"
        try await pool.withSession(for: host) { session in
            #expect(session.host.properties[RemoteHost.webdavBasePathKey] == "/remote.php/dav/files/duck")
        }
        #expect(factory.created == 2, "the settings changed, so the connection must be rebuilt")
    }

    @Test("A cosmetic edit still reuses the connection")
    func renamingDoesNotDropTheConnection() async throws {
        // The other half of the rule: a nickname is not a connection setting, and dropping a working
        // connection because someone renamed a bookmark would be its own bug.
        let factory = PerHostSessionFactory()
        let pool = SessionPool(factory: factory, delegate: ScriptedDelegate())

        var host = RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 22,
                              username: "duck", nickname: "Work")
        try await pool.withSession(for: host) { _ in }

        host.nickname = "Work – EU"
        host.comment = "notes"
        host.defaultPath = RemotePath("/srv")
        try await pool.withSession(for: host) { _ in }

        #expect(factory.created == 1)
    }

    @Test("A protocol error keeps the connection; a dead one is discarded")
    func keepsUsableConnections() async throws {
        let session = try await TransferFixture.makeSession()
        let factory = CountingSessionFactory(session: session)
        let pool = SessionPool(factory: factory, delegate: ScriptedDelegate())

        // "No such file" leaves the connection perfectly usable, so the next borrow must reuse it.
        await #expect(throws: SessionError.self) {
            try await pool.withSession(for: TransferFixture.host) { session in
                _ = try await session.stat(RemotePath("/nope"))
            }
        }
        try await pool.withSession(for: TransferFixture.host) { session in
            _ = try await session.list(.root)
        }

        #expect(factory.created == 1)
    }

    @Test("A factory that cannot build a session surfaces the error and frees the slot")
    func factoryFailurePropagates() async throws {
        let pool = SessionPool(
            factory: FailingSessionFactory(),
            delegate: ScriptedDelegate(),
            maxConnectionsPerHost: 1
        )

        for _ in 0..<3 {
            await #expect(throws: SessionError.unknownProtocol(.sftp)) {
                try await pool.withSession(for: TransferFixture.host) { _ in }
            }
        }
    }

    @Test("Connections are counted per host")
    func tracksConnectionCount() async throws {
        let session = try await TransferFixture.makeSession()
        let pool = TransferFixture.makePool(session: session)

        #expect(await pool.connectionCount(for: TransferFixture.host) == 0)
        try await pool.withSession(for: TransferFixture.host) { _ in }
        #expect(await pool.connectionCount(for: TransferFixture.host) == 1)

        await pool.disconnectAll()
        #expect(await pool.connectionCount(for: TransferFixture.host) == 0)
    }
}

/// Records how many borrowers held a connection at once.
private actor ConcurrencyTracker {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var completed = 0

    func enter() {
        current += 1
        peak = Swift.max(peak, current)
    }

    func leave() {
        current -= 1
        completed += 1
    }
}
