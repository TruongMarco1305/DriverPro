//
//  TransfersWindow.swift
//  DriverPro
//

import DPPresentation
import DPTransfer
import SwiftUI

/// Running and finished transfers.
struct TransfersWindow: View {

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            if let transfers = environment.transfers, !transfers.rows.isEmpty {
                List(transfers.rows) { row in
                    TransferRow(row: row, transfers: transfers)
                }
                .toolbar {
                    Button("Resume All") {
                        Task { await transfers.resumeAll() }
                    }
                    .help("Start every transfer interrupted by a quit")
                    .disabled(!transfers.rows.contains { $0.isInterrupted })

                    Button("Clear Finished") { transfers.clearFinished() }
                        .help("Remove every transfer that has ended")
                        .disabled(!transfers.rows.contains { $0.isFinished })
                }
            } else {
                ContentUnavailableView(
                    "No Transfers",
                    systemImage: "arrow.up.arrow.down.circle",
                    description: Text("Downloads and uploads appear here.")
                )
            }
        }
    }
}

private struct TransferRow: View {

    let row: TransferListModel.Row
    let transfers: TransferListModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.isDownload ? "arrow.down.circle" : "arrow.up.circle")
                .font(.title3)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).lineLimit(1)

                if row.isInterrupted {
                    // No bar: this one is standing still until the user says otherwise.
                    Text(interruptedDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let report = row.report {
                    Text(summary(report))
                        .font(.caption)
                        .foregroundStyle(report.isSuccess ? .secondary : Color.red)
                } else {
                    // An indeterminate bar when no total is known — a fraction would be a guess.
                    if let fraction = row.fractionCompleted {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if row.isInterrupted {
                Button("Resume") {
                    Task { await transfers.resume(row.id) }
                }
                .help("Continue this transfer where it left off")

                Button {
                    Task { await transfers.dismiss(row.id) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Forget this transfer")
            } else if row.isFinished {
                Button {
                    Task { await transfers.dismiss(row.id) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Remove from the list")
            } else {
                Button("Cancel") {
                    Task { await transfers.cancel(row.id) }
                }
                .help("Stop this transfer")
            }
        }
        .padding(.vertical, 4)
    }

    /// What an interrupted row says instead of a progress bar.
    private var interruptedDetail: String {
        guard row.transferredBytes > 0 else { return "Interrupted" }
        let moved = ByteCountFormatter.string(fromByteCount: row.transferredBytes, countStyle: .file)
        return "Interrupted — \(moved) transferred"
    }

    private var tint: Color {
        if row.isInterrupted { return .orange }
        guard let report = row.report else { return .accentColor }
        return report.isSuccess ? .secondary : .red
    }

    private var detail: String {
        let moved = ByteCountFormatter.string(fromByteCount: row.transferredBytes, countStyle: .file)
        guard let total = row.totalBytes else {
            return row.currentItem.map { "\($0) — \(moved)" } ?? moved
        }
        let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return row.currentItem.map { "\($0) — \(moved) of \(totalText)" } ?? "\(moved) of \(totalText)"
    }

    private func summary(_ report: TransferReport) -> String {
        if report.wasCancelled { return "Cancelled after \(report.transferred) file(s)" }
        if let failure = report.failure { return failure.errorDescription ?? "Failed" }

        var parts = ["\(report.transferred) transferred"]
        if report.skipped > 0 { parts.append("\(report.skipped) skipped") }
        if report.failed > 0 { parts.append("\(report.failed) failed") }
        return parts.joined(separator: ", ")
    }
}
