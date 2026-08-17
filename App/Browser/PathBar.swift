//
//  PathBar.swift
//  DriverPro
//

import DPCore
import DPPresentation
import SwiftUI

/// The breadcrumb above the listing. Each component navigates to that directory.
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
                    Button(path.isRoot ? "/" : path.name) {
                        Task { await browser.navigate(to: path) }
                    }
                    .buttonStyle(.plain)
                    .fontWeight(path == browser.path ? .semibold : .regular)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
        .background(.bar)
    }
}
