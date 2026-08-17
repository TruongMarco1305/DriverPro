//
//  PathBar.swift
//  DriverPro
//

import DPCore
import DPPresentation
import SwiftUI

/// The breadcrumb above the listing. Each component navigates to that directory.
///
/// The crumbs' text comes from `BrowserModel.breadcrumbLabel(for:)` — the root reads as the connection's
/// name, which is a naming rule and so belongs in the model rather than here.
struct PathBar: View {

    let browser: BrowserModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(Array(browser.breadcrumb.enumerated()), id: \.element) { index, path in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button(browser.breadcrumbLabel(for: path)) {
                        Task { await browser.navigate(to: path) }
                    }
                    .buttonStyle(.plain)
                    .fontWeight(path == browser.path ? .semibold : .regular)
                    .help(path.pathString)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
        .background(.bar)
    }
}
