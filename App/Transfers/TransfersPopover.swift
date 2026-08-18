//
//  TransfersPopover.swift
//  DriverPro
//

import DPPresentation
import DPTransfer
import SwiftUI

/// The toolbar button that opens the transfers panel, with a badge while anything is happening.
///
/// One place for transfers, attached to the window they belong to. A separate window meant progress
/// lived somewhere you had to know to look for.
struct TransfersButton: View {

    let transfers: TransferListModel

    @State private var isShowingPanel = false

    var body: some View {
        Button {
            isShowingPanel.toggle()
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
                .overlay(alignment: .topTrailing) {
                    // A dot rather than a count: the exact number is one click away, and a badge that
                    // changes width jitters the toolbar.
                    if badge != nil {
                        Circle()
                            .fill(badge == .interrupted ? Color.orange : Color.green)
                            .frame(width: 7, height: 7)
                            .offset(x: 4, y: -3)
                    }
                }
        }
        .help(helpText)
        .popover(isPresented: $isShowingPanel, arrowEdge: .bottom) {
            TransfersPanel(transfers: transfers) { isShowingPanel = false }
        }
    }

    private enum Badge { case active, interrupted }

    private var badge: Badge? {
        if transfers.activeCount > 0 { return .active }
        if transfers.interruptedCount > 0 { return .interrupted }
        return nil
    }

    private var helpText: String {
        switch badge {
        case .active: "\(transfers.activeCount) transferring"
        case .interrupted: "\(transfers.interruptedCount) interrupted — open to resume"
        case nil: "Downloads and uploads"
        }
    }
}

/// The panel itself: one row per file, newest first.
struct TransfersPanel: View {

    let transfers: TransferListModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads / Uploads").font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            if transfers.rows.isEmpty {
                ContentUnavailableView(
                    "No Transfers",
                    systemImage: "arrow.up.arrow.down.circle",
                    description: Text("Downloads and uploads appear here.")
                )
                .frame(height: 200)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(transfers.rows) { row in
                            TransferRowView(row: row, transfers: transfers)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)

                Divider()

                HStack {
                    Button("Resume All") {
                        Task { await transfers.resumeAll() }
                    }
                    .disabled(transfers.interruptedCount == 0)

                    Spacer()

                    Button("Clear Finished") { transfers.clearFinished() }
                        .disabled(!transfers.rows.contains(where: \.isFinished))
                }
                .padding(12)
            }
        }
        .frame(width: 420)
    }
}

/// One file, with where it is going and how far it has got.
private struct TransferRowView: View {

    let row: TransferListModel.Row
    let transfers: TransferListModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(row.state.isFailure ? Color.red : .secondary)
                    .lineLimit(1)

                if !row.isFinished && !row.isInterrupted {
                    HStack(spacing: 8) {
                        // Indeterminate when the size is unknown — a fraction there would be a guess.
                        if let fraction = row.fractionCompleted {
                            ProgressView(value: fraction)
                            Text(fraction, format: .percent.precision(.fractionLength(0)))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            if row.isInterrupted {
                Button("Resume") {
                    Task { await transfers.resume(row.transferID) }
                }
                .help("Continue this transfer where it left off")
            }

            Button {
                Task { await transfers.dismissRow(row.id) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(row.isFinished ? "Remove from the list" : "Stop this transfer")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The connection, plus what happened when that is the more useful thing to say.
    private var subtitle: String {
        switch row.state {
        case .failed(let message): message
        case .skipped: "Skipped — a copy was already there"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted — \(row.connection)"
        case .waiting, .moving, .done: row.connection
        }
    }

    private var symbol: String {
        switch row.state {
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .skipped: "minus.circle.fill"
        case .cancelled: "slash.circle.fill"
        case .interrupted: "pause.circle.fill"
        case .waiting, .moving: row.isDownload ? "arrow.down.circle" : "arrow.up.circle"
        }
    }

    private var tint: Color {
        switch row.state {
        case .done: .green
        case .failed: .red
        case .interrupted: .orange
        case .skipped, .cancelled: .secondary
        case .waiting, .moving: .accentColor
        }
    }
}

private extension TransferListModel.Row.State {
    /// Whether the subtitle should read as a problem.
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
