#if os(macOS)
import AppKit
import SwiftUI

struct DevicesPane: View {
    @Environment(Library.self) private var library
    @State private var nearby: [NearbyDevice] = []
    @State private var sharing = true
    @State private var advanced = false
    @AppStorage(Library.showsSyncActivity) private var showsSyncActivity = false
    @State private var address = ""

    var body: some View {
        Form {
            Section {
                ForEach(library.devices) { device in DeviceRow(device: device) }
            } header: {
                Text("Your Devices")
            } footer: {
                Text("Everyone who shares the library sees your devices' names. Removing a device refuses what it changes from then on, and your devices stop catching up with it; it leaves the library the next time it catches up, to be paired again only as a new device.")
            }
            Section {
                Toggle("Share this library on your network", isOn: $sharing)
                    .onChange(of: sharing) { library.sharing = sharing }
            } footer: {
                Text(library.servingPort != nil
                    ? "Your other devices, and the people who share the library, get your changes (such as where you are in what you're watching) from this Mac, and can play videos from its folders, while Cinematheque is open."
                    : "Your changes reach your other devices only when this Mac catches up with them.")
            }
            Section {
                ForEach(nearby.filter { $0.pairing != nil }) { device in
                    PairRow(device: device) { done in nearby.removeAll { $0.id == done.id } }
                }
                if !nearby.contains(where: { $0.pairing != nil }) { Looking() }
            } header: {
                Text("New Devices")
            } footer: {
                Text("A new device shows a code once Join a Library is chosen on it. Enter its code here, beside its name, then choose Yours or Someone New.")
            }
            Section("Advanced", isExpanded: $advanced) {
                ForEach(nearby.filter(\.added)) { device in
                    HStack {
                        Text(device.url).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        RemoveButton(help: "Forget this address") {
                            library.setDeviceAddress(device.url, false)
                            Task { nearby = await library.nearby() }
                        }
                    }
                }
                // As Add Server… takes a server's: the field's name its
                // prompt, the example in the text below.
                HStack {
                    TextField("Device Address", text: $address, prompt: Text("Device Address"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addAddress)
                    Button("Add", action: addAddress)
                        .disabled(!validAddress)
                }
            }
            if advanced {
                Footer("Devices off your network, such as one behind another router (NAT), can be reached by address, such as http://hal.example.com:8008.")
                Section {
                    Toggle("Show sync activity", isOn: $showsSyncActivity)
                } footer: {
                    Text("The last changes received from and sent to your devices, in the library window's status bar.")
                }
            }
        }
        .formStyle(.grouped)
        .modifier(Nearby(devices: $nearby))
        .onAppear { sharing = library.sharing }
    }

    private var validAddress: Bool { URL(string: address)?.scheme?.hasPrefix("http") == true }

    private func addAddress() {
        guard validAddress else { return }
        library.setDeviceAddress(address, true)
        address = ""
        Task { nearby = await library.nearby() }
    }
}

/// One of your devices, its name editable here: an Apple TV can't learn
/// the name it's given in its settings, so it names itself "Apple TV".
private struct DeviceRow: View {
    let device: Device
    @Environment(Library.self) private var library
    @State private var name = ""

    var body: some View {
        HStack {
            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .labelsHidden()
                .textFieldStyle(.plain)
                .onSubmit(rename)
                .help("Rename")
            if device.you {
                Text("This Mac").foregroundStyle(.secondary)
            } else {
                RemoveButton(help: "Remove from your devices") {
                    withAnimation { library.removeDevice(device.key) }
                }
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
        if device.you { library.setName(.device, name) } else { library.renameDevice(device.key, name) }
    }
}
#endif
