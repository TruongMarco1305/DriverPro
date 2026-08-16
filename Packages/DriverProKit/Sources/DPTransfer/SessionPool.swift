//
//  SessionPool.swift
//  DPTransfer
//

import DPCore
import Foundation

/// Lends connections, capped per host, reusing them instead of reconnecting.
///
/// Two reasons this exists. Operations on a single `Session` serialise — it is an actor — so parallel
/// transfers need parallel connections. And an SSH handshake costs far more than a small file transfer,
/// so a queue of 200 files would spend most of its time reconnecting if each borrowed a fresh session.
///
/// ## Swift note — an async semaphore
/// The per-host cap is enforced with a queue of `CheckedContinuation`s rather than a lock. A borrower
/// that finds every slot taken suspends; a returner hands its slot straight to the longest waiter. No
/// thread blocks, and because this is all inside an actor there is no lock to forget.
public actor SessionPool {

    // MARK: - Configuration

    private let factory: any SessionFactory
    private let delegate: any SessionDelegate
    private let maxConnectionsPerHost: Int

    // MARK: - State

    private var idle: [UUID: [any Session]] = [:]
    private var inUse: [UUID: Int] = [:]

    /// Free slots per host. Absent means untouched, and so equal to the limit.
    private var available: [UUID: Int] = [:]
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    /// Creates a pool.
    ///
    /// - Parameters:
    ///   - factory: Builds a session for a bookmark. Keeps the pool protocol-agnostic.
    ///   - delegate: Answers host key and credential questions during connection.
    ///   - maxConnectionsPerHost: How many connections one server may have at once. Four is polite;
    ///     small servers often refuse more.
    public init(
        factory: any SessionFactory,
        delegate: any SessionDelegate,
        maxConnectionsPerHost: Int = 4
    ) {
        self.factory = factory
        self.delegate = delegate
        self.maxConnectionsPerHost = maxConnectionsPerHost
    }

    // MARK: - Borrowing

    /// Runs `body` with a connected session, returning it to the pool afterwards.
    ///
    /// Suspends while the host is at its connection limit. The session is returned on every path,
    /// including a thrown error — otherwise a run of failures would leak every connection and stall the
    /// queue permanently.
    ///
    /// - Parameters:
    ///   - host: Which server to connect to.
    ///   - body: Work to do with the session.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Connection failures, or whatever `body` throws.
    public func withSession<T: Sendable>(
        for host: RemoteHost,
        _ body: sending (any Session) async throws -> T
    ) async throws -> T {
        let session = try await borrow(host)

        do {
            let result = try await body(session)
            await release(session, for: host)
            return result
        } catch {
            // A protocol-level failure such as "file not found" leaves the connection perfectly usable,
            // so only a genuinely dead session is discarded. Discarding on every error would make a
            // directory full of unreadable files reconnect once per file.
            if await session.isConnected {
                await release(session, for: host)
            } else {
                await discard(session, for: host)
            }
            throw error
        }
    }

    /// Closes every connection and forgets them.
    public func disconnectAll() async {
        for sessions in idle.values {
            for session in sessions { await session.disconnect() }
        }
        idle.removeAll()
    }

    /// Connections currently held for a host, idle or lent out. Exposed for tests.
    /// - Parameter host: The bookmark to count.
    public func connectionCount(for host: RemoteHost) -> Int {
        (idle[host.id]?.count ?? 0) + (inUse[host.id] ?? 0)
    }

    // MARK: - Internals

    private func borrow(_ host: RemoteHost) async throws -> any Session {
        await acquireSlot(host.id)

        // Reuse an idle connection if one survived. Checking `isConnected` needs an `await`, and the
        // actor can be re-entered during it — but the slot is already reserved, so a concurrent borrower
        // cannot exceed the cap while this runs.
        while let candidate = idle[host.id]?.popLast() {
            if await candidate.isConnected {
                inUse[host.id, default: 0] += 1
                return candidate
            }
        }

        do {
            let session = try factory.makeSession(for: host)
            try await session.connect(credentials: nil, delegate: delegate)
            inUse[host.id, default: 0] += 1
            return session
        } catch {
            // The slot was reserved before connecting, so it has to be handed back on failure.
            releaseSlot(host.id)
            throw error
        }
    }

    private func release(_ session: any Session, for host: RemoteHost) async {
        inUse[host.id, default: 1] -= 1
        idle[host.id, default: []].append(session)
        releaseSlot(host.id)
    }

    private func discard(_ session: any Session, for host: RemoteHost) async {
        inUse[host.id, default: 1] -= 1
        await session.disconnect()
        releaseSlot(host.id)
    }

    // MARK: - Slot accounting

    /// Takes a slot, waiting if the host is already at its limit.
    private func acquireSlot(_ hostID: UUID) async {
        let free = available[hostID] ?? maxConnectionsPerHost
        if free > 0 {
            available[hostID] = free - 1
            return
        }
        // No slot free. Suspend; a returning borrower will hand its slot straight over, which is why
        // nothing is decremented after being resumed.
        await withCheckedContinuation { continuation in
            waiters[hostID, default: []].append(continuation)
        }
    }

    /// Gives the slot to the longest-waiting borrower, or back to the pool if nobody is waiting.
    private func releaseSlot(_ hostID: UUID) {
        if var queue = waiters[hostID], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[hostID] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            available[hostID] = (available[hostID] ?? maxConnectionsPerHost) + 1
        }
    }
}
