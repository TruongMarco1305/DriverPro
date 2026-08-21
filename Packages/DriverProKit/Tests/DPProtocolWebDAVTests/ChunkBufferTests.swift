//
//  ChunkBufferTests.swift
//  DPProtocolWebDAVTests
//

import Foundation
import Testing
@testable import DPProtocolWebDAV

@Suite("ChunkBuffer")
struct ChunkBufferTests {

    private func chunk(_ bytes: Int) -> Data {
        Data(repeating: 0xAB, count: bytes)
    }

    @Test("Chunks come out in the order they went in")
    func preservesOrder() async throws {
        // The whole reason this is a locked queue rather than an actor reached from the delegate: a
        // task per chunk would reorder the file, and a reordered file is a corrupt one.
        let buffer = ChunkBuffer()
        for byte in UInt8(1)...5 {
            buffer.append(Data([byte]))
        }
        buffer.finish()

        var received: [UInt8] = []
        while let next = try await buffer.next() {
            received.append(contentsOf: next)
        }
        #expect(received == [1, 2, 3, 4, 5])
    }

    @Test("A consumer that arrives first waits, and is handed the chunk directly")
    func consumerWaits() async throws {
        let buffer = ChunkBuffer()

        async let received = buffer.next()
        try await Task.sleep(for: .milliseconds(20))    // let the consumer get there first
        buffer.append(chunk(10))

        #expect(try await received?.count == 10)
    }

    @Test("Finishing wakes a waiting consumer with nothing")
    func finishWakesTheConsumer() async throws {
        // Without this a download whose server closes early hangs forever rather than ending.
        let buffer = ChunkBuffer()

        async let received = buffer.next()
        try await Task.sleep(for: .milliseconds(20))
        buffer.finish()

        #expect(try await received == nil)
    }

    @Test("A failure reaches the consumer rather than looking like the end of the file")
    func failurePropagates() async throws {
        struct Interrupted: Error {}
        let buffer = ChunkBuffer()

        // A `Task` rather than `async let`: `#expect(throws:)` captures its body in a closure, and an
        // `async let` variable cannot be captured.
        let received = Task { try await buffer.next() }
        try await Task.sleep(for: .milliseconds(20))
        buffer.finish(throwing: Interrupted())

        await #expect(throws: Interrupted.self) { _ = try await received.value }
    }

    // MARK: - Backpressure

    @Test("Filling past the high mark asks the producer to pause")
    func pausesAtHighWater() {
        let buffer = ChunkBuffer(highWater: 1_000, lowWater: 400)

        #expect(buffer.append(chunk(300)) == .carryOn)
        #expect(buffer.append(chunk(300)) == .carryOn)
        #expect(buffer.append(chunk(500)) == .pause, "1,100 bytes held is past the mark")
        #expect(buffer.depth == 1_100)
    }

    @Test("Draining past the low mark tells the producer to carry on — once, not per chunk")
    func resumesAtLowWater() async throws {
        // Two marks rather than one: with a single threshold, a producer sitting exactly at the limit
        // suspends and resumes on every chunk, which costs more than the buffering saves.
        let resumed = Counter()
        let buffer = ChunkBuffer(highWater: 1_000, lowWater: 400)
        buffer.onResume = { resumed.increment() }

        buffer.append(chunk(600))
        #expect(buffer.append(chunk(600)) == .pause)

        _ = try await buffer.next()          // 600 left — still above the low mark
        #expect(resumed.value == 0)

        _ = try await buffer.next()          // 0 left — below it
        #expect(resumed.value == 1)

        // Draining further must not keep announcing it.
        buffer.append(chunk(100))
        _ = try await buffer.next()
        #expect(resumed.value == 1)
    }

    @Test("Memory stays flat when the consumer is slower than the producer")
    func staysFlatUnderPressure() async throws {
        // The property M1's acceptance cares about, in miniature: a producer that respects the pause
        // never holds more than the high mark, however much it has to send.
        let buffer = ChunkBuffer(highWater: 4_000, lowWater: 2_000)
        let observed = Counter()

        let producer = Task {
            for _ in 0..<200 {
                let pressure = buffer.append(self.chunk(1_000))
                observed.max(buffer.depth)

                // A real producer suspends its URLSession task here and is resumed by `onResume`; this
                // one waits for the same condition. Note it does *not* append again while waiting —
                // doing so is how a producer defeats the very backpressure it was told to respect.
                while pressure == .pause, buffer.depth > 2_000 {
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            buffer.finish()
        }

        var total = 0
        while let next = try await buffer.next() {
            total += next.count
            try await Task.sleep(for: .microseconds(200))     // a deliberately slow consumer
        }
        _ = try await producer.value

        #expect(total == 200_000, "every byte still arrives")
        #expect(observed.peak <= 5_000, "held \(observed.peak) bytes, which is past the mark")
    }

    /// A counter safe to touch from two tasks, for observing what the buffer did.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var highest = 0

        var value: Int { lock.withLock { count } }
        var peak: Int { lock.withLock { highest } }

        func increment() { lock.withLock { count += 1 } }
        func max(_ candidate: Int) { lock.withLock { highest = Swift.max(highest, candidate) } }
    }
}
