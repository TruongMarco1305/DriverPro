//
//  TransferStatusBar.swift
//  DriverPro
//

import DPPresentation
import SwiftUI

/// A strip along the bottom of the browser showing what is moving right now.
///
/// Without it a download gave no feedback at all: the Transfers window existed but nothing opened it and
/// nothing pointed at it. Clicking here does.
struct TransferStatusBar: View {

    let summary: TransferListModel.ActiveSummary
    let show: () -> Void

    @State private var isHovered = false

    /// What the bar says: what is moving, or what is waiting to be resumed.
    private var label: String {
        guard summary.activeCount == 0 else { return summary.title }
        return summary.interruptedCount == 1
            ? "\(summary.title) — interrupted"
            : "\(summary.interruptedCount) interrupted transfers"
    }

    var body: some View {
        Button(action: show) {
            HStack(spacing: 10) {
                if summary.activeCount == 0 {
                    // Nothing is moving. A bar here would claim otherwise.
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.orange)
                } else if let fraction = summary.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 120)
                } else {
                    // Indeterminate when no total is known — a fraction there would be a guess.
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                }

                Text(label)
                    .font(.callout)
                    .lineLimit(1)

                if summary.activeCount > 1 {
                    Text("+\(summary.activeCount - 1) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(.rect)
            .background(isHovered ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(summary.activeCount == 0
              ? "Interrupted transfers are waiting — open Transfers to resume them (⌥⌘T)"
              : "Show transfers (⌥⌘T)")
    }
}
