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
    @FocusState private var focus: SettingsRow?

    private var me: Member? { library.members.first(where: \.you) }
    private var others: [Member] { library.members.filter { !$0.you } }
    /// The founder's only device: leaving takes the founder with it, so it
    /// hands the library over first, or, if no one else is in it, ends it.
    /// The system's rows' text (and headings') inset in its plate, wider
    /// than a form's.
    static let rowInsets = EdgeInsets(top: 0, leading: 30, bottom: 0, trailing: 30)

    private var foundersOnly: Bool { me?.founder == true && library.status?.others == 0 }

    var body: some View {
        SettingsPage(explanation: explanation) { list }
    }

    /// What the focused row does; a problem leaving, whatever's focused.
    private var explanation: String {
        if leaving { return "Leaving…" }
        if let problem { return problem }
        return focus?.explanation ?? ""
    }

    private var list: some View {
        Form {
            Section {
                nameRow("This Apple TV", library.devices.first(where: \.you)?.name, .device)
                    .settingsRow(.device, $focus)
                nameRow("You", me?.name, .person)
                    .settingsRow(.person, $focus)
            } header: {
                Text("Names").bold()
            }
            .listRowInsets(Self.rowInsets)
            Section {
                Button("Refresh Library") {
                    Task { await library.refresh() }
                }
                .disabled(library.activity != nil || leaving)
                .settingsRow(.refresh, $focus)
                // A row opening its choices, as tvOS's Settings has them
                // (a picker's `.navigationLink` style opens an empty list).
                NavigationLink {
                    IntervalPage()
                } label: {
                    LabeledContent("Look for New Videos", value: Library.crawlChoices.first { $0.hours == library.crawlEvery }?.name ?? "")
                }
                .settingsRow(.interval, $focus)
                Toggle("Show Sync Activity", isOn: $showsSyncActivity)
                    .settingsRow(.activity, $focus)
            } header: {
                Text("Library").bold()
            }
            .listRowInsets(Self.rowInsets)
            Section {
                Button("Leave This Library…", role: .destructive, action: askToLeave)
                    .disabled(leaving)
                    .settingsRow(.leave, $focus)
            }
            .listRowInsets(Self.rowInsets)
        }
        // Narrowed, it would clip a focused row, which grows past its edges.
        .scrollClipDisabled()
        #if DEBUG
        // Once the library's people are read.
        .task(id: me?.key) {
            guard me != nil, let how = Launch.leave else { return }
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
    /// holding the name (an unseen UIKit field's: a SwiftUI field in a row
    /// draws a plate of its own in the row's and crowds the name); saved as
    /// it's submitted (a blank one ignored), and Back leaves it as it was.
    private func nameRow(_ title: String, _ name: String?, _ which: Library.Named) -> some View {
        Button { naming = which } label: {
            LabeledContent(title) {
                // On one line, as the system's values, so rows keep one height.
                Text(name ?? "Unnamed").lineLimit(1)
            }
        }
        .background {
            KeyboardField(title: title, text: name ?? "", typing: Binding(get: { naming == which }, set: { if !$0 { naming = nil } })) {
                library.setName(which, $0)
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

/// A row of Settings, by what it does.
private enum SettingsRow: Hashable {
    case device, person, refresh, interval, activity, leave

    /// Shown under the picture as the row's focused, and read by VoiceOver
    /// as its hint, since what's shown only on focus it never reaches.
    var explanation: String {
        switch self {
        case .device, .person: "Everyone in the library sees these names."
        case .refresh, .interval: "Refresh Library looks for new videos in the library's sources. Otherwise your devices look as often as chosen, as they open; a NAS's disks spin up each time."
        case .activity: "The last changes received from and sent to your devices, in the corner after each."
        case .leave: "Returns to setup, to join a library again, as yours or someone else's."
        }
    }
}

private extension View {
    /// A row of Settings, followed by focus for its explanation, which is
    /// its hint too.
    func settingsRow(_ row: SettingsRow, _ focus: FocusState<SettingsRow?>.Binding) -> some View {
        focused(focus, equals: row)
            .accessibilityHint(row.explanation)
    }
}

/// Look for New Videos' choices, as tvOS's Settings lists a setting's: the
/// current one checked and focused first; choosing one sets it and goes
/// back.
private struct IntervalPage: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Int?

    var body: some View {
        SettingsPage(explanation: SettingsRow.interval.explanation) {
            Form {
                Section {
                    ForEach(Library.crawlChoices, id: \.hours) { choice in
                        Button {
                            library.setCrawlEvery(choice.hours)
                            dismiss()
                        } label: {
                            LabeledContent(choice.name) {
                                if choice.hours == library.crawlEvery { Image(systemName: "checkmark") }
                            }
                        }
                        .focused($focus, equals: choice.hours)
                        .accessibilityAddTraits(choice.hours == library.crawlEvery ? .isSelected : [])
                    }
                } header: {
                    Text("Look for New Videos").bold()
                }
                .listRowInsets(SettingsView.rowInsets)
            }
            .scrollClipDisabled()
            .defaultFocus($focus, library.crawlEvery)
        }
    }
}

/// A page laid out as tvOS's Settings lays its out, by its proportions of
/// the screen (measured on its 1920 by 1080 points): the app's icon a
/// little below the middle of the left 55%, and low under it, 40% of the
/// screen wide, what the focused row does; the list from there to 4% short
/// of the right edge, in the system's row text size (`.headline`), under
/// the tab bar.
private struct SettingsPage<List: View>: View {
    let explanation: String
    @ViewBuilder let list: List

    private static var left: CGFloat { 1056 / 1920 }
    private static var listWidth: CGFloat { 788 / 1920 }
    private static var pictureWidth: CGFloat { 540 / 1920 }
    private static var pictureCenter: CGFloat { 506 / 1080 }
    private static var explanationWidth: CGFloat { 768 / 1920 }
    private static var explanationCenter: CGFloat { 940 / 1080 }

    var body: some View {
        GeometryReader { screen in
            let width = screen.size.width
            HStack(spacing: 0) {
                GeometryReader { pane in
                    Image("SettingsIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 24))
                        .frame(width: width * Self.pictureWidth)
                        .position(x: pane.size.width / 2, y: pane.size.height * Self.pictureCenter)
                        .accessibilityHidden(true)
                    Text(explanation)
                        // VoiceOver reads it as each row's hint instead.
                        .accessibilityHidden(true)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                        .animation(.default, value: explanation)
                        .frame(width: width * Self.explanationWidth, height: pane.size.height / 6, alignment: .top)
                        .position(x: pane.size.width / 2, y: pane.size.height * Self.explanationCenter)
                }
                // The whole height, behind the tab bar too, as the system's.
                .ignoresSafeArea(edges: .vertical)
                .frame(width: width * Self.left)
                list
                    .formStyle(.grouped)
                    .font(.headline)
                    .frame(width: width * Self.listWidth)
                Spacer(minLength: 0)
            }
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
        // Unseen, so VoiceOver reads only its row (SwiftUI's
        // accessibilityHidden doesn't reach a UIKit view).
        field.accessibilityElementsHidden = true
        field.isAccessibilityElement = false
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
