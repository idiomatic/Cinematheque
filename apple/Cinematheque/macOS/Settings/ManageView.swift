#if os(macOS)
import AppKit
import SwiftUI
import SystemConfiguration

/// Settings: the people who share the library, your devices (this Mac's
/// sharing among them), named in place, where videos come from, and where
/// downloads go; addresses are kept under Advanced.
struct ManageView: View {
    var body: some View {
        TabView {
            Tab("People", systemImage: "person.2") { PeoplePane() }
            Tab("Devices", systemImage: "laptopcomputer.and.iphone") { DevicesPane() }
            Tab("Sources", systemImage: "externaldrive.connected.to.line.below") { SourcesPane() }
            Tab("Downloads", systemImage: "arrow.down.circle") { DownloadsPane() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ProblemBar() }
        .frame(width: 640, height: 480)
    }
}

/// Removing a row's member, device, or address: a symbol, explained by its
/// help.
struct RemoveButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button("Remove", systemImage: "minus.circle", role: .destructive, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(help)
    }
}

/// A footer for the section above it that can't have one, as a collapsible
/// section can't: a section of its own, empty but for the footer.
struct Footer: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Section {
        } footer: {
            Text(text)
        }
    }
}

/// While looking for new devices nearby, and none is found yet.
struct Looking: View {
    var body: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text("Looking for new devices nearby…").foregroundStyle(.secondary)
        }
    }
}
#endif
