#if os(tvOS)
import SwiftUI

// Settings' pages for the library's people, your devices, and its sources,
// as the Mac's panes have them, laid out as tvOS's Settings lays out a
// subpage: a list, each row explaining itself under the picture as it's
// focused. Pressing a row acts on it (asking first what to do, or whether
// to), as rows in tvOS have no buttons of their own.

/// The library's people: you, the founder, and others, any of whom (but the
/// founder) you may remove; and adding someone, by their device's code.
struct PeoplePage: View {
    @Environment(Library.self) private var library
    @State private var adding = false
    /// Someone to remove, once confirmed: they come back only as someone new.
    @State private var removing: Member?
    @FocusState private var focus: String?

    var body: some View {
        SettingsPage(title: "People", explanation: explanation) {
            Form {
                Section {
                    ForEach(library.members) { member in
                        Button { if removable(member) { removing = member } } label: {
                            ValueLabel(title: member.name ?? "Someone Unnamed", value: [member.you ? "You" : nil, member.founder ? "Founder" : nil].compactMap(\.self).joined(separator: ", "))
                        }
                        .explained("member:" + member.key, hint(member), $focus)
                    }
                }
                .listRowInsets(SettingsView.rowInsets)
                Section {
                    Button { adding = true } label: { ValueLabel(title: "Add Someone", opens: true, value: "") }
                        .explained("add", "Adds someone with their own progress and watchlist, by the code their device shows as it joins.", $focus)
                }
                .listRowInsets(SettingsView.rowInsets)
            }
            .scrollClipDisabled()
        }
        .navigationDestination(isPresented: $adding) { AddDevicePage(join: true) }
        // Hard to undo, so asked first.
        .confirmationDialog(
            "Remove \(removing?.name ?? "Them")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { member in
            Button("Remove", role: .destructive) { library.removeMember(member.key) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("They and their devices leave the library, and what they change from then on is refused. To come back, they join again as someone new; their watchlist and progress don't come back with them.")
        }
        #if DEBUG
        .onAppear { if Launch.adds { adding = true } }
        #endif
    }

    private var explanation: String {
        guard let focus else { return SettingsRow.people.explanation }
        return focus == "add" ? "Adds someone with their own progress and watchlist, by the code their device shows as it joins." : library.members.first { "member:" + $0.key == focus }.map(hint) ?? ""
    }

    private func removable(_ member: Member) -> Bool { !member.you && !member.founder }

    private func hint(_ member: Member) -> String {
        if member.you { return "You, by the name everyone in the library sees, which you change under Names." }
        if member.founder { return "Founded the library, so stays in it until they hand it over, as they leave." }
        return "Press to remove them from the library, with their devices."
    }
}

/// Your devices, each (but this one) renamed or removed by pressing it; and
/// adding another, by its code.
struct DevicesPage: View {
    @Environment(Library.self) private var library
    @State private var adding = false
    /// A device pressed: what to do with it, asked.
    @State private var acting: Device?
    /// The device whose name's keyboard is up.
    @State private var renaming: String?
    @FocusState private var focus: String?

    var body: some View {
        SettingsPage(title: "Your Devices", explanation: explanation) {
            Form {
                Section {
                    // This one first, as the one you're using.
                    ForEach(library.devices.filter(\.you) + library.devices.filter { !$0.you }) { device in
                        Button { if !device.you { acting = device } } label: {
                            ValueLabel(title: device.name, value: device.you ? "This Apple TV" : "")
                        }
                        .background {
                            KeyboardField(title: "Name", text: device.name, typing: Binding(get: { renaming == device.key }, set: { if !$0 { renaming = nil } })) {
                                library.renameDevice(device.key, $0)
                            }
                            .frame(width: 1, height: 1)
                            .clipped()
                            .opacity(0.01)
                            .accessibilityHidden(true)
                        }
                        .explained("device:" + device.key, hint(device), $focus)
                    }
                }
                .listRowInsets(SettingsView.rowInsets)
                Section {
                    Button { adding = true } label: { ValueLabel(title: "Add a Device", opens: true, value: "") }
                        .explained("add", Self.adding, $focus)
                }
                .listRowInsets(SettingsView.rowInsets)
            }
            .scrollClipDisabled()
        }
        .navigationDestination(isPresented: $adding) { AddDevicePage(join: false) }
        .confirmationDialog(
            acting?.name ?? "",
            isPresented: Binding(get: { acting != nil }, set: { if !$0 { acting = nil } }),
            titleVisibility: .visible,
            presenting: acting
        ) { device in
            Button("Rename") { renaming = device.key }
            Button("Remove", role: .destructive) { library.removeDevice(device.key) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Removed, it leaves the library the next time it catches up, and comes back only by joining again.")
        }
        #if DEBUG
        .onAppear { if Launch.adds { adding = true } }
        #endif
    }

    static let adding = "Adds another of your devices, sharing your progress and watchlist, by the code it shows as it joins. Add only your own: each can act as you."

    private var explanation: String {
        guard let focus else { return SettingsRow.devices.explanation }
        return focus == "add" ? Self.adding : library.devices.first { "device:" + $0.key == focus }.map(hint) ?? ""
    }

    private func hint(_ device: Device) -> String {
        device.you
            ? "This Apple TV, by the name your other devices know it by, which you change under Names."
            : "Press to rename it, or to remove it if you've given it away or no longer use it."
    }
}

/// The library's sources (but devices' downloads, theirs to manage), each
/// removed by pressing it, once confirmed; and adding a server by its
/// address. A Mac adds its folders, and sets where a source's quality
/// comes from.
struct SourcesPage: View {
    @Environment(Library.self) private var library
    @State private var typing = false
    /// A source to remove, once confirmed: its videos go on every device.
    @State private var removing: Source?
    @State private var problem: String?
    @FocusState private var focus: String?

    private var sources: [Source] { library.sources.filter { !$0.managed } }

    var body: some View {
        SettingsPage(title: "Sources", explanation: problem ?? explanation) {
            Form {
                Section {
                    ForEach(sources) { source in
                        Button { removing = source } label: {
                            ValueLabel(title: source.displayName, value: source.copies == 1 ? "1 video" : "\(source.copies.formatted()) videos")
                        }
                        .explained("source:" + source.id, hint(source), $focus)
                    }
                }
                .listRowInsets(SettingsView.rowInsets)
                Section {
                    Button { problem = nil; typing = true } label: { ValueLabel(title: "Add Server", opens: true, value: "") }
                        .background {
                            KeyboardField(title: "Server Address", text: "http://", keyboard: .URL, typing: $typing, submit: add)
                                .frame(width: 1, height: 1)
                                .clipped()
                                .opacity(0.01)
                                .accessibilityHidden(true)
                        }
                        .explained("add", Self.adding, $focus)
                }
                .listRowInsets(SettingsView.rowInsets)
            }
            .scrollClipDisabled()
        }
        // Removing a source can't be undone but by adding it again and
        // looking for its videos anew.
        .confirmationDialog(
            "Remove “\(removing?.displayName ?? "")”?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { source in
            Button("Remove", role: .destructive) { library.removeSource(source.id) }
            Button("Cancel", role: .cancel) {}
        } message: { source in
            Text("\(source.copies == 1 ? "Its one video goes" : "Its \(source.copies.formatted()) videos go") from the library, on every device, though its files stay where they are. You can add it again.")
        }
        #if DEBUG
        .onAppear { if let server = Launch.server { add(server) } }
        #endif
    }

    static let adding = "Adds a folder of videos on a server, such as a NAS, by its address as a browser would open it: http://nas.local/Video/Movies/."

    private var explanation: String {
        guard let focus else { return SettingsRow.sources.explanation }
        return focus == "add" ? Self.adding : sources.first { "source:" + $0.id == focus }.map(hint) ?? ""
    }

    private func hint(_ source: Source) -> String {
        let gone = source.unavailable.count
        let unavailable = gone == 0 ? "" : " \(gone == 1 ? "A folder" : "\(gone) folders") of it, as on a drive unplugged, \(gone == 1 ? "is" : "are") unavailable; manage them on a Mac."
        return "Press to remove it, and its videos, on every device." + unavailable
    }

    /// Adds the server typed, and looks for its videos; one that isn't a web
    /// address is explained, to type again.
    private func add(_ typed: String) {
        let address = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address != "http://", !address.isEmpty else { return }
        guard URL(web: address) != nil else {
            problem = "“\(address)” isn't a server's address, which starts with http:// or https://, as http://nas.local/Video/Movies/ does."
            return
        }
        problem = nil
        library.addSource(address, skip: ",")
        Task { await library.crawl() }
    }
}

/// Adding a device: one nearby offering to be added (as it shows Join a
/// Library), chosen, then the code it shows, typed. As this person's own
/// (sharing their secret, so it can act as them), or someone new's (`join`).
/// Added, it goes back to the list, where the device now is; Cancel, or
/// Back, goes back without adding one.
struct AddDevicePage: View {
    let join: Bool
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var nearby: [NearbyDevice] = []
    /// The device whose code's keyboard is up.
    @State private var entering: String?
    @State private var pairing: NearbyDevice?
    @State private var problem: String?

    private var offering: [NearbyDevice] { nearby.filter { $0.pairing != nil } }

    var body: some View {
        SettingsPage(title: join ? "Add Someone" : "Add a Device", explanation: explanation) {
            Form {
                Section {
                    ForEach(offering) { device in
                        Button { problem = nil; entering = device.url } label: {
                            ValueLabel(title: device.deviceName ?? "A New Device", opens: true, value: pairing?.url == device.url ? "Adding…" : "")
                        }
                        .disabled(pairing != nil)
                        .background {
                            KeyboardField(title: "The code \(device.deviceName ?? "it") shows", text: "", keyboard: .numberPad, typing: Binding(get: { entering == device.url }, set: { if !$0 { entering = nil } })) {
                                pair(device, $0)
                            }
                            .frame(width: 1, height: 1)
                            .clipped()
                            .opacity(0.01)
                            .accessibilityHidden(true)
                        }
                        .accessibilityHint(explanation)
                    }
                    if offering.isEmpty {
                        HStack(spacing: 20) {
                            ProgressView()
                            Text("Looking for new devices nearby…").foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowInsets(SettingsView.rowInsets)
                // A way out that takes focus, as nothing else may (with no
                // device found yet), and Back goes from what's focused.
                Section {
                    Button("Cancel") { dismiss() }
                        .accessibilityHint("Goes back without adding anyone.")
                }
                .listRowInsets(SettingsView.rowInsets)
            }
            .scrollClipDisabled()
        }
        .modifier(Nearby(devices: $nearby))
        #if DEBUG
        // `CINEMATHEQUE_PAIR`: a code for the first device found.
        .task(id: offering.first?.url) {
            if let device = offering.first, let code = Launch.pair { pair(device, code) }
        }
        #endif
    }

    private var explanation: String {
        if let problem { return problem }
        if let pairing { return "Adding \(pairing.deviceName ?? "the device")…" }
        return join
            ? "On their device, have them choose Join a Library, then choose it here and enter the code it shows. They keep their own progress and watchlist."
            : "On your device, choose Join a Library, then choose it here and enter the code it shows. Add only your own: it can act as you, sharing your progress and watchlist."
    }

    private func pair(_ device: NearbyDevice, _ typed: String) {
        let code = typed.filter(\.isNumber)
        guard code.count == CodeBoxes.length else {
            problem = "The code is \(CodeBoxes.length) digits, as \(device.deviceName ?? "the device") shows it. Choose it again to enter it."
            return
        }
        pairing = device
        problem = nil
        Task {
            let (joined, why) = join ? await library.pairMember(device, code: code) : await library.pairPerson(device, code: code)
            pairing = nil
            guard let joined else {
                problem = why ?? "Couldn't add it."
                return
            }
            if join { library.welcomeMember(joined, from: device) } else { library.welcome(joined, from: device) }
            dismiss()
        }
    }
}

private extension View {
    /// A page's row, followed by focus for its explanation, which is its
    /// hint too.
    func explained(_ id: String, _ hint: String, _ focus: FocusState<String?>.Binding) -> some View {
        focused(focus, equals: id)
            .accessibilityHint(hint)
    }
}
#endif
