#if os(tvOS)
import SwiftUI

/// The Apple TV's settings, its tab bar's last: its name and its person's,
/// Refresh Library, and Leave This Library…, which returns to setup, to
/// pair again as another's device or join another library. Adding sources
/// and people stays on the Mac.
struct SettingsView: View {
    @Environment(Library.self) private var library
    /// The name being edited, and its draft.
    @State private var editing: Library.Named?
    @State private var draft = ""
    @State private var confirmingLeave = false
    @State private var choosingSuccessor = false
    @State private var leaving = false
    @State private var problem: String?

    private var me: Member? { library.members.first(where: \.you) }
    private var others: [Member] { library.members.filter { !$0.you } }
    /// The founder's only device: leaving takes the founder with it, so it
    /// hands the library over first, or, if no one else is in it, ends it.
    private var foundersOnly: Bool { me?.founder == true && library.status?.others == 0 }

    var body: some View {
        List {
            Section("Names") {
                nameRow("This Apple TV", library.devices.first(where: \.you)?.name, .device)
                nameRow("You", me?.name, .person)
            }
            Section {
                Button("Refresh Library", systemImage: "arrow.clockwise") {
                    Task { await library.refresh() }
                }
                .disabled(library.activity != nil || leaving)
                Picker("Look for New Videos", selection: Binding(get: { library.crawlEvery }, set: { library.setCrawlEvery($0) })) {
                    ForEach(Library.crawlChoices, id: \.hours) { Text($0.name).tag($0.hours) }
                }
                // A row opening its choices, as tvOS's Settings has them.
                .pickerStyle(.navigationLink)
            } footer: {
                Text("Refresh Library catches up with your other devices, then looks for new videos in the library's sources. Otherwise your devices look as often as chosen, as they open; a NAS's disks spin up each time.")
            }
            Section {
                Button("Leave This Library…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: askToLeave)
                .disabled(leaving)
            } footer: {
                Text(leaving ? "Leaving…" : problem ?? "Returns to setup, to pair this Apple TV as another of your devices, or to join another library.")
            }
        }
        .frame(maxWidth: 1100)
        #if DEBUG
        .task {
            guard let how = Launch.leave else { return }
            // Once the library's people are read.
            for _ in 0..<50 where me == nil { try? await Task.sleep(for: .milliseconds(200)) }
            askToLeave()
            guard how == "confirm" else { return }
            try? await Task.sleep(for: .seconds(1))
            if choosingSuccessor, let first = others.first {
                choosingSuccessor = false
                leave(successor: first.key, alone: false)
            } else if confirmingLeave {
                confirmingLeave = false
                leave(successor: nil, alone: foundersOnly)
            }
        }
        #endif
        .alert(editing == .person ? "Your Name" : "This Apple TV's Name", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Name", text: $draft)
            Button("Save") { if let which = editing { library.setName(which, draft) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone in the library sees it.")
        }
        // Hard to undo, so asked first.
        .alert(foundersOnly ? "End This Library?" : "Leave This Library?", isPresented: $confirmingLeave) {
            Button(foundersOnly ? "Leave and End It" : "Leave", role: .destructive) { leave(successor: nil, alone: foundersOnly) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(foundersOnly
                ? "No one else is in this library, so once this Apple TV leaves, it's gone for good. Its videos stay where they are."
                : "This Apple TV leaves the library, and your other devices no longer list it. To come back, pair it again.")
        }
        // The founder's only device leaving: someone takes over first.
        .confirmationDialog("Who takes over the library?", isPresented: $choosingSuccessor, titleVisibility: .visible) {
            ForEach(others) { member in
                Button(member.name ?? "Someone Unnamed") { leave(successor: member.key, alone: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You founded this library, and this Apple TV is your only device in it, so someone takes over as its founder before it leaves.")
        }
    }

    private func nameRow(_ title: String, _ name: String?, _ which: Library.Named) -> some View {
        Button {
            draft = name ?? ""
            editing = which
        } label: {
            LabeledContent(title, value: name ?? "Unnamed")
        }
    }

    /// Asks first: who takes over, if the founder's only device leaves with
    /// others in the library; else whether to leave.
    private func askToLeave() {
        if foundersOnly, !others.isEmpty { choosingSuccessor = true } else { confirmingLeave = true }
    }

    private func leave(successor: String?, alone: Bool) {
        leaving = true
        problem = nil
        Task {
            problem = await library.leaveLibrary(successor: successor, alone: alone)
            leaving = false
        }
    }
}
#endif
