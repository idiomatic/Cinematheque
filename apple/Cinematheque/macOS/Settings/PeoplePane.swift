#if os(macOS)
import AppKit
import SwiftUI

struct PeoplePane: View {
    @Environment(Library.self) private var library
    @State private var nearby: [NearbyDevice] = []

    var body: some View {
        Form {
            Section {
                ForEach(library.members) { member in MemberRow(member: member) }
                ForEach(waiting) { device in
                    HStack {
                        Label((device.personName ?? "Someone") + "’s " + (device.deviceName ?? "device"), systemImage: "person.crop.circle.badge.questionmark")
                        Text("wants to join").foregroundStyle(.secondary)
                        Spacer()
                        Button("Add") {
                            if let key = device.person_key { library.setMember(key, true) }
                        }
                    }
                }
            } header: {
                Text("People")
            } footer: {
                Text("Everyone who shares the library sees your name. To add someone, they choose Join Someone's Library on their device, which shows a code: enter it in Devices, under New Devices. Removing someone refuses what they change from then on; their devices leave the library the next time each catches up.")
            }
        }
        .formStyle(.grouped)
        .modifier(Nearby(devices: $nearby))
    }

    /// Devices of this library nearby whose people aren't members yet.
    /// (New devices offering to pair have no library yet.)
    private var waiting: [NearbyDevice] {
        var seen: Set<String> = []
        return nearby.filter { $0.ours && !$0.member && !$0.added && $0.person_key != nil && seen.insert($0.person_key!).inserted }
    }
}

/// A member of the library; you, by a name editable here.
private struct MemberRow: View {
    let member: Member
    @Environment(Library.self) private var library
    @State private var name = ""

    var body: some View {
        HStack {
            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
            if member.you {
                TextField("Your name", text: $name, prompt: Text("Your name"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .fixedSize()
                    .onSubmit { library.setName(.person, name) }
                    .help("Rename yourself")
                Text("You").foregroundStyle(.secondary)
            } else {
                Text(member.name ?? "Someone")
            }
            Spacer()
            if member.founder {
                Text("Founder").foregroundStyle(.secondary)
            } else if !member.you {
                RemoveButton(help: "Remove from the library, with their devices") {
                    library.setMember(member.key, false)
                }
            }
        }
        .onAppear { name = member.name ?? "" }
        .onChange(of: member.name) { name = member.name ?? "" }
        .onDisappear { if member.you, name != (member.name ?? "") { library.setName(.person, name) } }
    }
}
#endif
