#if os(macOS)
import AppKit
import SwiftUI
import SystemConfiguration

/// Settings: the people who share the library, your devices (this Mac's
/// sharing among them, and devices by address), named in place, where
/// videos come from, and where downloads go; nothing behind a toggle.
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

/// While looking for new devices nearby, and none is found yet.
struct Looking: View {
    var body: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text("Looking for new devices nearby…").foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// A row's symbol in one width, whatever its own (a laptop's is wider
    /// than a phone's), so the rows' names line up, as an iOS list lines
    /// them up and a Mac form doesn't.
    func rowSymbol() -> some View {
        frame(width: 24)
    }
}
#endif
