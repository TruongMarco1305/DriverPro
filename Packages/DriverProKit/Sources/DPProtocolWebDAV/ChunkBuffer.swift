//
//  ChunkBuffer.swift
//  DPProtocolWebDAV
//

import Foundation

/// A queue of chunks between a producer that cannot wait and a consumer that can.
///
/// ## Why this exists
/// `URLSessionDataDelegate` hands over data in a **synchronous** callback — there is nowhere to `await`
/// inside it, so a slow consumer cannot be made to slow the producer down by suspending it. Left alone,
/// a fast server and a slow disk buffer the entire file in memory, which is exactly what M1's acceptance
/// criterion ("500 MB, flat memory") exists to catch.
///
/// So the buffer counts what it is holding and reports whether the producer should pause. The delegate
/// acts on that by calling `suspend()` on its task, and `resume()` when the consumer has drained enough.
/// Two marks rather than one, because a single threshold makes a task that is exactly at the limit
/// suspend and resume on every chunk.
///
/// A `final class` with a lock rather than an actor: `append` is called from a synchronous delegate
/// method, and an actor could only be reached from there by spawning a task per chunk — which would
/// reorder the file.
final class ChunkBuffer: @unchecked Sendable {

    /// What the producer should do after appending.
    enum Pressure: Equatable {
        /// Keep going.
        case carryOn
        /// Stop sending until told otherwise.
        case pause
    }

    private let lock = NSLock()
    private var chunks: [Data] = []
    private var bytesHeld = 0
    private var isFinished = false
    private var failure: (any Error)?

    /// A consumer waiting for the next chunk, when the buffer was empty.
    private var waiter: CheckedContinuation<Data?, any Error>?
    /// Whether the producer was told to pause and is waiting to be told otherwise.
    private var isPaused = false

    /// Bytes held before the producer is asked to stop.
    private let highWater: Int
    /// Bytes it must fall to before the producer is told to carry on.
    private let lowWater: Int

    /// Creates a buffer.
    ///
    /// - Parameters:
    ///   - highWater: Hold this many bytes before pausing the producer. The default is a few network
    ///     buffers' worth: enough that a brief disk stall does not stall the socket, small enough that
    ///     memory stays flat on a file of any size.
    ///   - lowWater: Resume once it falls to this. Half of `highWater` by default.
    init(highWater: Int = 4 * 1_024 * 1_024, lowWater: Int? = nil) {
        self.highWater = highWater
        self.lowWater = lowWater ?? highWater / 2
    }

    /// How much is being held. For tests, and for the assertion that this works at all.
    var depth: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytesHeld
    }

    // MARK: - Producing

    /// Adds a chunk, and says whether to keep going.
    ///
    /// - Parameter chunk: Bytes from the network.
    /// - Returns: Whether the producer should pause.
    @discardableResult
    func append(_ chunk: Data) -> Pressure {
        lock.lock()

        // A consumer already waiting takes the chunk directly. Queueing it first would mean holding it
        // while someone is asking for it.
        if let waiting = waiter {
            waiter = nil
            lock.unlock()
            waiting.resume(returning: chunk)
            return .carryOn
        }

        chunks.append(chunk)
        bytesHeld += chunk.count

        let shouldPause = bytesHeld >= highWater
        if shouldPause { isPaused = true }
        lock.unlock()

        return shouldPause ? .pause : .carryOn
    }

    /// Says there is no more data.
    ///
    /// - Parameter error: Why it stopped, if it stopped badly.
    func finish(throwing error: (any Error)? = nil) {
        lock.lock()
        isFinished = true
        failure = error

        let waiting = waiter
        waiter = nil
        lock.unlock()

        guard let waiting else { return }
        if let error {
            waiting.resume(throwing: error)
        } else {
            waiting.resume(returning: nil)
        }
    }

    // MARK: - Consuming

    /// The next chunk, waiting if there is none yet.
    ///
    /// - Returns: The chunk, or `nil` once the producer has finished.
    /// - Throws: Whatever the producer finished with.
    func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()

            if !chunks.isEmpty {
                let chunk = chunks.removeFirst()
                bytesHeld -= chunk.count

                // Draining past the low mark is what lets the producer start again. Reported through
                // the return value rather than acted on here: this type holds no reference to the task,
                // which is what keeps it testable without a network.
                let shouldResume = isPaused && bytesHeld <= lowWater
                if shouldResume { isPaused = false }
                lock.unlock()

                if shouldResume { onResume?() }
                continuation.resume(returning: chunk)
                return
            }

            if isFinished {
                let error = failure
                lock.unlock()
                error.map { continuation.resume(throwing: $0) }
                    ?? continuation.resume(returning: nil)
                return
            }

            waiter = continuation
            lock.unlock()
        }
    }

    /// Called when the consumer has drained enough for the producer to carry on.
    ///
    /// Set by whoever owns the producer — the download delegate sets it to resume its task.
    var onResume: (@Sendable () -> Void)?
}
