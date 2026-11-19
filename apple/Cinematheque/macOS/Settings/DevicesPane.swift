#if os(macOS)
import AppKit
import SwiftUI

struct DevicesPane: View {
    @Environment(Library.self) private var library
    @State private var nearby: [NearbyDevice] = []
    @State private var sharing = true
    @State private var advanced = false
    @State private var address = ""

    var body: some View {
        Form {
            Section {
                ForEach(library.devices) { device in DeviceRow(device: device) }
            } header: {
                Text("Your Devices")
            } footer: {
                Text("Everyone who shares the library sees your devices' names.")
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
                Text("To add another of your devices, choose I Use Cinematheque on Another Device on it; to add someone, they choose Join Someone's Library on theirs. Either shows a code: enter it here, beside its name.")
            }
            Section("Advanced", isExpanded: $advanced) {
                ForEach(nearby.filter(\.added)) { device in
                    HStack {
                        Text(device.url).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        RemoveButton(help: "Stop reaching it by this address") {
                            library.setDeviceAddress(device.url, false)
                            Task { nearby = await library.nearby() }
                        }
                    }
                }
                HStack {
                    Text("Address")
                    TextField("Address", text: $address, prompt: Text("http://hal.example.com:8008"))
                        .labelsHidden()
                    Button("Add") {
                        library.setDeviceAddress(address, true)
                        address = ""
                        Task { nearby = await library.nearby() }
                    }
                    .disabled(URL(string: address)?.scheme?.hasPrefix("http") != true)
                }
            }
            if advanced {
                Footer("Devices off your network, such as one behind another router (NAT), can be reached by address.")
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
        HStack {
            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .labelsHidden()
                .textFieldStyle(.plain)
                .onSubmit(rename)
            if device.you {
                Text("This Mac").foregroundStyle(.secondary)
            } else {
                RemoveButton(help: "Remove it from your devices: what it changes from now on is refused, and your devices stop catching up with it. It leaves the library the next time it catches up, within about a minute if it's on. It could still be paired again, as a new device.") {
                    withAnimation { library.removeDevice(device.key) }
                }
            }
        }
        .help("Rename it for everyone in the library")
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
