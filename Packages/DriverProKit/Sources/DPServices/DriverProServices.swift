//
//  DriverProServices.swift
//  DPServices
//

import DPBookmarks
import DPCore
import DPCredentials
import DPDatabase
import DPTransfer
import Foundation

/// The engine, assembled.
///
/// Built once and handed to the user interface. Everything below it is independent and separately
/// tested; this is the only place they meet, which is why it is small enough to read in one sitting.
///
/// A `struct` of references rather than an actor: it holds actors and coordinates them, but has no
/// mutable state of its own to protect.
public struct DriverProServices: Sendable {

    /// The shared connection, backing bookmarks now and the transfer queue in M2.
    public let database: Database
    /// Saved connections.
    public let bookmarks: BookmarkStore
    /// Where passwords live.
    public let credentials: any CredentialStore
    /// Trusted SSH host keys.
    public let knownHosts: KnownHostsStore
    /// Which protocols exist, and how to build a session for one.
    public let catalog: ProtocolCatalog
    /// Lends connections, capped per host.
    public let pool: SessionPool
    /// Runs transfers.
    public let queue: TransferQueue

    private let coordinator: CredentialCoordinator

    // MARK: - Building

    /// Assembles the engine from parts.
    ///
    /// Every dependency is injected so tests can substitute an in-memory database, an in-memory
    /// credential store, and a scripted prompt. ``live(prompt:databaseURL:)`` is the production path.
    ///
    /// - Parameters:
    ///   - database: An open database, migrated with ``BookmarkStore/migrations``.
    ///   - credentials: Where passwords are kept.
    ///   - knownHosts: Where SSH host keys are read and recorded.
    ///   - prompt: How to reach the user.
    ///   - catalog: Supported protocols. Defaults to ``ProtocolCatalog/live``.
    ///   - sessionFactory: Overrides how sessions are built. Defaults to the catalog's own factory;
    ///     tests substitute an in-memory backend so the wiring can be exercised without a server.
    ///   - maxConnectionsPerHost: How many connections one server may have at once.
    ///   - maxConcurrentFiles: How many files move at once.
    public init(
        database: Database,
        credentials: any CredentialStore,
        knownHosts: KnownHostsStore,
        prompt: any UserPrompt,
        catalog: ProtocolCatalog = .live,
        sessionFactory: (any SessionFactory)? = nil,
        maxConnectionsPerHost: Int = 4,
        maxConcurrentFiles: Int = 4
    ) {
        self.database = database
        self.credentials = credentials
        self.knownHosts = knownHosts
        self.catalog = catalog
        self.bookmarks = BookmarkStore(database: database)

        let coordinator = CredentialCoordinator(store: credentials, prompt: prompt)
        self.coordinator = coordinator

        let pool = SessionPool(
            factory: sessionFactory ?? catalog.makeSessionFactory(knownHosts: knownHosts),
            delegate: coordinator,
            maxConnectionsPerHost: maxConnectionsPerHost
        )
        self.pool = pool
        self.queue = TransferQueue(pool: pool, maxConcurrentFiles: maxConcurrentFiles)
    }

    /// The production configuration: a database in Application Support, and the user's `~/.ssh/known_hosts`.
    ///
    /// - Parameters:
    ///   - prompt: How to reach the user.
    ///   - databaseURL: Where to keep the database. Defaults to
    ///     ``BookmarkStore/defaultDatabaseURL``.
    /// - Returns: A fully wired engine.
    /// - Throws: ``DatabaseError`` if the database cannot be opened or migrated.
    public static func live(prompt: any UserPrompt, databaseURL: URL? = nil) throws -> DriverProServices {
        let database = try Database(
            .file(databaseURL ?? BookmarkStore.defaultDatabaseURL),
            migrations: BookmarkStore.migrations
        )
        return DriverProServices(
            database: database,
            credentials: KeychainStore(),
            knownHosts: KnownHostsStore(),
            prompt: prompt
        )
    }

    // MARK: - Connecting

    /// Opens a connection to a bookmark, asking the user only for what the stores cannot supply.
    ///
    /// The connection stays in the pool afterwards, so browsing and transfers reuse it rather than
    /// handshaking again.
    ///
    /// - Parameter host: The bookmark to connect to.
    /// - Throws: ``SessionError/authenticationFailed(reason:)`` if the credentials are refused or the
    ///   user cancels, ``SessionError/hostKeyRejected`` if the key is declined, or
    ///   ``SessionError/unreachable(host:reason:)``.
    public func connect(to host: RemoteHost) async throws {
        do {
            // Borrowing is what triggers the handshake, and therefore the delegate.
            try await pool.withSession(for: host) { _ in }
        } catch {
            await coordinator.discardPending(for: host)
            throw error
        }
        // Only now is the password known to be right.
        await coordinator.persistPending(for: host)
    }

    /// Connects if needed, then runs `body` with a live session.
    ///
    /// The entry point the browser uses for listing, renaming, and deleting.
    ///
    /// - Parameters:
    ///   - host: The bookmark to work against.
    ///   - body: What to do with the session.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Connection failures, or whatever `body` throws.
    public func withSession<T: Sendable>(
        for host: RemoteHost,
        _ body: sending (any Session) async throws -> T
    ) async throws -> T {
        let result: T
        do {
            result = try await pool.withSession(for: host, body)
        } catch {
            await coordinator.discardPending(for: host)
            throw error
        }
        await coordinator.persistPending(for: host)
        return result
    }

    /// Closes every pooled connection. Call on quit, or sockets linger.
    public func disconnectAll() async {
        await pool.disconnectAll()
    }
}
