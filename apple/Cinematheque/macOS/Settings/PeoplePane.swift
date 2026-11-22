#if os(macOS)
import AppKit
import SwiftUI

struct PeoplePane: View {
    @Environment(Library.self) private var library
    @State private var confirmingLeave = false
    @State private var choosingSuccessor = false
    @State private var leaving = false
    @State private var problem: String?
    /// Closes Settings once this Mac has left: there's nothing to set.
    @Environment(\.dismiss) private var dismiss

    private var me: Member? { library.members.first(where: \.you) }
    private var others: [Member] { library.members.filter { !$0.you } }
    /// The founder's only device: leaving takes the founder with it, so it
    /// hands the library over first, or, if no one else is in it, ends it.
    private var foundersOnly: Bool { me?.founder == true && library.status?.others == 0 }

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
                Button("Leave This Library…", action: askToLeave)
                    .disabled(leaving)
            } footer: {
                Text(leaving ? "Leaving…" : problem ?? "This Mac leaves the library and returns to its welcome window, to join a library again or create another.")
            }
        }
        .formStyle(.grouped)
        // Hard to undo, so asked first.
        .alert(foundersOnly ? "End This Library?" : "Leave This Library?", isPresented: $confirmingLeave) {
            Button(foundersOnly ? "Leave and End It" : "Leave", role: .destructive) { if foundersOnly { end() } else { leave(successor: nil) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(foundersOnly
                ? "No one else is in this library, so once this Mac leaves, it's gone for good. Its videos stay where they are."
                : "This Mac leaves the library, and your other devices no longer list it. To come back, join again.")
        }
        // The founder's only device leaving: someone takes over first.
        .confirmationDialog("Who takes over the library?", isPresented: $choosingSuccessor, titleVisibility: .visible) {
            ForEach(others) { member in
                Button(member.name ?? "Someone Unnamed") { leave(successor: member.key) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You founded this library, and this Mac is your only device in it, so someone takes over as its founder before it leaves.")
        }
    }

    /// Asks first: who takes over, if the founder's only device leaves with
    /// others in the library; else whether to leave.
    private func askToLeave() {
        if foundersOnly, !others.isEmpty { choosingSuccessor = true } else { confirmingLeave = true }
    }

    private func leave(successor: String?) { leaving { await library.leaveLibrary(successor: successor) } }

    /// Leaves a library no one else is in, ending it.
    private func end() { leaving { await library.endLibrary() } }

    private func leaving(_ by: @escaping () async -> String?) {
        leaving = true
        problem = nil
        Task {
            problem = await by()
            leaving = false
            if problem == nil, !library.hasLibrary { dismiss() }
        }
    }
}

/// A member of the library; you, by a name editable here.
private struct MemberRow: View {
    let member: Member
    @Environment(Library.self) private var library
    @State private var name = ""
    /// Removing someone is confirmed first: they can come back only by
    /// joining again, as someone new.
    @State private var confirmingRemoval = false

    var body: some View {
        LabeledContent {
            if member.founder {
                Text("Founder")
            } else if !member.you {
                RemoveButton(help: "Remove from the library, with their devices") {
                    confirmingRemoval = true
                }
            }
        } label: {
            Label {
                if member.you {
                    TextField("Your name", text: $name, prompt: Text("Your name"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .onSubmit { library.setName(.person, name) }
                        .help("Rename yourself")
                    Text("You")
                } else {
                    Text(member.name ?? "Someone")
                }
            } icon: {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Remove \(member.name ?? "Them")?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) { library.removeMember(member.key) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They and their devices leave the library, and what they change from then on is refused. To come back, they join again as someone new; their watchlist and progress don't come back with them.")
        }
        .onAppear { name = member.name ?? "" }
        .onChange(of: member.name) { name = member.name ?? "" }
        .onDisappear { if member.you, name != (member.name ?? "") { library.setName(.person, name) } }
    }
}
#endif
