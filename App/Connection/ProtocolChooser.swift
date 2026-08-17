//
//  ProtocolChooser.swift
//  DriverPro
//

import DPCore
import DPServices
import SwiftUI

/// The first step of connecting: what kind of server is this?
///
/// Built entirely from `ProtocolCatalog`, so WebDAV in M3 appears here by adding a descriptor — icon,
/// name and explanation included. Protocols DriverPro cannot yet speak are absent rather than greyed
/// out: the catalog says what exists.
struct ProtocolChooser: View {

    let catalog: ProtocolCatalog
    let choose: (ProtocolIdentifier) -> Void
    let cancel: () -> Void

    /// Which row is picked. Local, because nothing outside cares until Continue is pressed.
    ///
    /// Nothing starts selected: the step should be answered deliberately, and Continue stays disabled
    /// until it is, so Return cannot commit to a protocol nobody chose.
    @State private var selected: ProtocolIdentifier?
    /// Which row the pointer is over.
    @State private var hovered: ProtocolIdentifier?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose a Connection Type").font(.headline)
                Text("This decides what DriverPro speaks to the server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            VStack(spacing: 6) {
                ForEach(catalog.descriptors) { descriptor in
                    row(for: descriptor)
                }
            }
            .padding(.horizontal, 16)

            Divider().padding(.top, 16)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                Button("Continue") {
                    if let selected { choose(selected) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
            .padding(12)
        }
    }

    private func row(for descriptor: ProtocolDescriptor) -> some View {
        let isSelected = selected == descriptor.id

        return Button {
            selected = descriptor.id
        } label: {
            HStack(spacing: 12) {
                // Fixed width so the names line up however wide each symbol draws.
                Image(systemName: descriptor.iconName)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.displayName).font(.headline)
                    Text(descriptor.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0)
            }
            .multilineTextAlignment(.leading)
            .padding(10)
            .contentShape(.rect)
            .background(fill(for: descriptor.id, isSelected: isSelected), in: .rect(cornerRadius: 8))
            // A border rather than a stronger tint, so selection and hover read as different states
            // rather than as degrees of the same one.
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 1.5 : 0)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? descriptor.id : (hovered == descriptor.id ? nil : hovered) }
        // Double-clicking a row is the same as picking it and pressing Continue.
        .simultaneousGesture(TapGesture(count: 2).onEnded { choose(descriptor.id) })
        .help(descriptor.summary)
    }

    /// Selection wins over hover, so pointing at the picked row does not change it.
    private func fill(for id: ProtocolIdentifier, isSelected: Bool) -> Color {
        if isSelected { return .accentColor.opacity(0.15) }
        return hovered == id ? Color.primary.opacity(0.06) : .clear
    }
}
