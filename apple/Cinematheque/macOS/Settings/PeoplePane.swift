#if os(macOS)
import AppKit
import SwiftUI

struct PeoplePane: View {
    @Environment(Library.self) private var library
    @State private var leaving = Leaving()
    /// Closes Settings once this Mac has left: there's nothing to set.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                ForEach(library.members) { member in MemberRow(member: member) }
            } header: {
                Text("People")
            } footer: {
                Text("Share the library with the people you watch with: each keeps their own progress and watchlist. To add someone, have them choose Join a Library on their device, then enter the code it shows in Devices, under New Devices, as Someone New.")
            }
            Section {
                Button("Leave This Library…", action: leaving.ask)
                    .disabled(leaving.underWay)
            } footer: {
                Text(leaving.underWay ? "Leaving…" : leaving.problem ?? "This Mac leaves the library and returns to its welcome window, to join a library again or create another.")
            }
        }
        .formStyle(.grouped)
        .confirmsLeaving(leaving) { if !library.hasLibrary { dismiss() } }
    }
}

/// A member of the library; you, by a name editable here.
private struct MemberRow: View {
    let member: Member
    @Environment(Library.self) private var library
    @State private var name = ""
    @State private var removing: Member?

    var body: some View {
        LabeledContent {
            if !member.you {
                RemoveButton(help: "Remove from the library, with their devices") {
                    removing = member
                }
            }
        } label: {
            Label {
                if member.you {
                    TextField("Your name", text: $name, prompt: Text("Your name"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .onSubmit { library.setPersonName(name) }
                        .help("Rename yourself")
                    Text("You")
                } else {
                    Text(member.name ?? "Someone")
                }
            } icon: {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
            }
        }
        .confirmsRemoving(member: $removing)
        .onAppear { name = member.name ?? "" }
        .onChange(of: member.name) { name = member.name ?? "" }
        .onDisappear { if member.you, name != (member.name ?? "") { library.setPersonName(name) } }
    }
}
#endif
