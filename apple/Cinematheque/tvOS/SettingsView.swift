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
    @AppStorage(Library.showsSyncActivity) private var showsSyncActivity = false
    /// The focused row, whose explanation shows under the picture.
    @FocusState private var focus: Row?

    private enum Row: Hashable { case device, person, refresh, interval, activity, leave }

    private var me: Member? { library.members.first(where: \.you) }
    private var others: [Member] { library.members.filter { !$0.you } }
    /// The founder's only device: leaving takes the founder with it, so it
    /// hands the library over first, or, if no one else is in it, ends it.
    private var foundersOnly: Bool { me?.founder == true && library.status?.others == 0 }

    var body: some View {
        // As tvOS's Settings: a picture in the left half, and under it what
        // the focused row does; the list in the right.
        HStack(spacing: 80) {
            VStack(spacing: 60) {
                AppIcon()
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 640, minHeight: 160, alignment: .top)
                    .animation(.default, value: focus)
            }
            .frame(maxWidth: .infinity)
            list
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 80)
    }

    /// What the focused row does; a problem leaving, whatever's focused.
    private var explanation: String {
        if leaving { return "Leaving…" }
        if let problem { return problem }
        switch focus {
        case .device, .person: return "Everyone in the library sees these names."
        case .refresh, .interval: return "Refresh Library looks for new videos in the library's sources. Otherwise your devices look as often as chosen, as they open; a NAS's disks spin up each time."
        case .activity: return "The last changes received from and sent to your devices, in the corner after each."
        case .leave: return "Returns to setup, to join a library again, as yours or someone else's."
        case nil: return ""
        }
    }

    private var list: some View {
        List {
            Section("Names") {
                nameRow("This Apple TV", library.devices.first(where: \.you)?.name, .device)
                    .focused($focus, equals: .device)
                nameRow("You", me?.name, .person)
                    .focused($focus, equals: .person)
            }
            Section("Library") {
                Button("Refresh Library") {
                    Task { await library.refresh() }
                }
                .disabled(library.activity != nil || leaving)
                .focused($focus, equals: .refresh)
                Picker("Look for New Videos", selection: Binding(get: { library.crawlEvery }, set: { library.setCrawlEvery($0) })) {
                    ForEach(Library.crawlChoices, id: \.hours) { Text($0.name).tag($0.hours) }
                }
                // A row opening its choices, as tvOS's Settings has them.
                .pickerStyle(.navigationLink)
                .focused($focus, equals: .interval)
                Toggle("Show Sync Activity", isOn: $showsSyncActivity)
                    .focused($focus, equals: .activity)
            }
            Section {
                Button("Leave This Library…", role: .destructive, action: askToLeave)
                    .disabled(leaving)
                    .focused($focus, equals: .leave)
            }
        }
        // Each row on a rounded plate, headings small and uppercase.
        .listStyle(.grouped)
        // Narrowed, it would clip a focused row, which grows past its edges.
        .scrollClipDisabled()
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

    /// The app's icon, as its placeholder icons draw it (draw-icons.swift):
    /// Settings' picture of what it sets.
    private struct AppIcon: View {
        var body: some View {
            RoundedRectangle(cornerRadius: 24)
                .fill(LinearGradient(
                    colors: [Color(red: 0.62, green: 0.07, blue: 0.12), Color(red: 0.30, green: 0.02, blue: 0.07)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 320, height: 192)
                .overlay {
                    Image(systemName: "film.stack")
                        .font(.system(size: 96))
                        .foregroundStyle(.white)
                }
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
