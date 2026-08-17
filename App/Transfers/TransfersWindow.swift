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

                if let report = row.report {
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

            if row.isFinished {
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

    private var tint: Color {
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
