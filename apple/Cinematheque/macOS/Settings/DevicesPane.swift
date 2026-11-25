#if os(macOS)
import AppKit
import SwiftUI

struct DevicesPane: View {
    @Environment(Library.self) private var library
    @State private var nearby: [NearbyDevice] = []
    @State private var sharing = true

    var body: some View {
        Form {
            Section {
                ForEach(library.devices) { device in DeviceRow(device: device) }
            } header: {
                Text("Your Devices")
            } footer: {
                Text("Names tell your devices apart wherever they're listed. Remove one you've given away or no longer use: it leaves the library the next time it catches up, and comes back only by joining again.")
            }
            Section {
                Toggle("Share this library on your network", isOn: $sharing)
                    .onChange(of: sharing) { library.sharing = sharing }
            } footer: {
                Text(library.servingPort != nil
                    ? "Lets your other devices, and the people you share the library with, catch up with this Mac (such as where you stopped watching), and play from its folders and downloads, while Cinematheque is open."
                    : "Share so your other devices get your changes and can play from this Mac; until then, they get your changes only when this Mac catches up with them.")
            }
            Section {
                ForEach(nearby.filter { $0.pairing != nil }) { device in
                    PairRow(device: device) { done in nearby.removeAll { $0.id == done.id } }
                }
                if !nearby.contains(where: { $0.pairing != nil }) { Looking() }
            } header: {
                Text("New Devices")
            } footer: {
                Text("To add a device, choose Join a Library on it, and enter the code it shows here. Choose Yours for your own device, or Someone New to give the person using it their own progress and watchlist.")
            }
        }
        .formStyle(.grouped)
        .modifier(Nearby(devices: $nearby))
        .onAppear { sharing = library.sharing }
    }
}

/// One of your devices, its name editable here: an Apple TV can't learn
/// the name it's given in its settings, so it names itself "Apple TV".
private struct DeviceRow: View {
    let device: Device
    @Environment(Library.self) private var library
    @State private var name = ""

    var body: some View {
        LabeledContent {
            if device.you {
                Text("This Mac")
            } else {
                HStack {
                    Text(device.seenText).foregroundStyle(.secondary)
                    RemoveButton(help: "Remove from your devices") {
                        withAnimation { library.removeDevice(device.key) }
                    }
                }
            }
        } label: {
            Label {
                TextField("Name", text: $name)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .onSubmit(rename)
                    .help("Rename")
            } icon: {
                // Its kind's symbol, as Apple's own lists of devices show it.
                Image(systemName: device.symbol).foregroundStyle(.secondary)
                    .rowSymbol()
            }
        }
        .onAppear { name = device.name }
        .onChange(of: device.name) { name = device.name }
        // A name typed but not submitted is kept on leaving the pane.
        .onDisappear { if name != device.name { rename() } }
    }

    /// This Mac's name is advertised too, so it's set as this device's;
    /// another's, under this person.
    private func rename() {
        if device.you { library.setDeviceName(name) } else { library.renameDevice(device.key, name) }
    }
}
#endif
