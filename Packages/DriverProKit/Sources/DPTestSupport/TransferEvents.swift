//
//  TransferEvents.swift
//  DPTestSupport
//

import DPTransfer
import Foundation

extension AsyncStream where Element == TransferEvent {
    /// Drains the stream into an array.
    ///
    /// Only for tests — production code reacts to events as they arrive rather than waiting for the
    /// transfer to end.
    public func collect() async -> [TransferEvent] {
        var events: [TransferEvent] = []
        for await event in self { events.append(event) }
        return events
    }
}

extension Array where Element == TransferEvent {

    /// The terminal report, if the run produced one.
    public var report: TransferReport? {
        for event in self {
            if case .finished(let report) = event { return report }
        }
        return nil
    }

    /// Cumulative byte counts, in the order they were reported.
    public var progressBytes: [Int64] {
        compactMap { event in
            if case .progress(let bytes, _) = event { return bytes }
            return nil
        }
    }

    /// Outcomes paired with the item they belong to.
    public var outcomes: [(TransferItem, ItemOutcome)] {
        compactMap { event in
            if case .itemFinished(let item, let outcome) = event { return (item, outcome) }
            return nil
        }
    }
}
