#if os(tvOS)
import SwiftUI

/// The Apple TV's settings, its tab bar's last: its name and its person's,
/// Refresh Library, and Leave This Library…, which returns to setup, to
/// pair again as another's device or join another library. Adding sources
/// and people stays on the Mac.
struct SettingsView: View {
    @Environment(Library.self) private var library
    @State private var confirmingLeave = false
    @State private var choosingSuccessor = false
    @State private var leaving = false
    @State private var problem: String?
    /// The name whose keyboard is up.
    @State private var naming: Library.Named?
    @AppStorage(Library.showsSyncActivity) private var showsSyncActivity = false
    /// The focused row, whose explanation shows under the picture.
    @FocusState private var focus: Row?

    private enum Row: Hashable { case device, person, refresh, interval, activity, leave }

    private var me: Member? { library.members.first(where: \.you) }
    private var others: [Member] { library.members.filter { !$0.you } }
    /// The founder's only device: leaving takes the founder with it, so it
    /// hands the library over first, or, if no one else is in it, ends it.
    /// The system's rows' text inset in its plate, wider than a form's.
    private static let rowInsets = EdgeInsets(top: 0, leading: 30, bottom: 0, trailing: 30)

    private var foundersOnly: Bool { me?.founder == true && library.status?.others == 0 }

    var body: some View {
        SettingsPage(explanation: explanation) { list }
            .animation(.default, value: focus)
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
        Form {
            Section {
                nameRow("This Apple TV", library.devices.first(where: \.you)?.name, .device)
                    .focused($focus, equals: .device)
                nameRow("You", me?.name, .person)
                    .focused($focus, equals: .person)
            } header: {
                Text("Names").bold()
            }
            .listRowInsets(Self.rowInsets)
            Section {
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
            } header: {
                Text("Library").bold()
            }
            .listRowInsets(Self.rowInsets)
            Section {
                Button("Leave This Library…", role: .destructive, action: askToLeave)
                    .disabled(leaving)
                    .focused($focus, equals: .leave)
            }
            .listRowInsets(Self.rowInsets)
        }
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


    /// A name: pressing it brings up the full-screen keyboard at once,
    /// holding the name (an unseen UIKit field's, as SwiftUI's fields need
    /// pressing themselves); saved as it's submitted (a blank one
    /// ignored), and Back leaves it as it was.
    private func nameRow(_ title: String, _ name: String?, _ which: Library.Named) -> some View {
        Button { naming = which } label: {
            LabeledContent(title, value: name ?? "Unnamed")
        }
        .background {
            KeyboardField(title: title, text: name ?? "", typing: Binding(get: { naming == which }, set: { if !$0 { naming = nil } })) {
                let new = $0.trimmingCharacters(in: .whitespaces)
                if !new.isEmpty { library.setName(which, new) }
            }
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityHidden(true)
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

/// The app's icon, as its placeholder icons draw it (draw-icons.swift):
/// Settings' picture of what it sets.
private struct AppIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(LinearGradient(
                colors: [Color(red: 0.62, green: 0.07, blue: 0.12), Color(red: 0.30, green: 0.02, blue: 0.07)],
                startPoint: .top, endPoint: .bottom))
            .frame(width: 540, height: 324)
            .overlay {
                Image(systemName: "film.stack")
                    .font(.system(size: 160))
                    .foregroundStyle(.white)
            }
    }
}

/// A page laid out as tvOS's Settings lays its out, measured against it
/// across the screen (1920 points): the app's icon a little below the
/// middle of the left 55%, and low under it, 40% of the screen wide, what
/// the focused row does; the list from there to 4% short of the right edge.
private struct SettingsPage<List: View>: View {
    let explanation: String
    @ViewBuilder let list: List

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                AppIcon()
                    .position(x: 528, y: 506)
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 768, height: 180, alignment: .top)
                    .position(x: 528, y: 940)
            }
            .frame(width: 1056, height: 1080)
            .ignoresSafeArea()
            list
                .formStyle(.grouped)
                // The system's rows' text size.
                .font(.headline)
                .frame(width: 788)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea(edges: .horizontal)
    }
}

/// A UIKit text field, unseen, whose keyboard comes up full screen as
/// `typing` turns on, holding `text`; `submit` takes what's typed when it's
/// submitted, not when it's dismissed.
private struct KeyboardField: UIViewRepresentable {
    let title: String
    let text: String
    @Binding var typing: Bool
    let submit: (String) -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.returnKeyType = .done
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if typing, !field.isFirstResponder {
            field.placeholder = title
            field.text = text
            field.becomeFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: KeyboardField

        init(_ parent: KeyboardField) { self.parent = parent }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.submit(field.text ?? "")
            field.resignFirstResponder()
            return false
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            parent.typing = false
        }
    }
}
#endif
