#if os(tvOS)
import SwiftUI

/// The Apple TV's settings, a section's page: its name and its person's;
/// the library's people, your devices, and its sources, each a page for
/// adding and removing them, as the Mac's panes; Refresh Library; and
/// Leave This Library…, which returns to setup, to pair again as another's
/// device or join another library. A Mac's folders, and what sets a
/// source's quality, stay on the Mac.
struct SettingsView: View {
    @Environment(Library.self) private var library
    @State private var confirmingLeave = false
    @State private var choosingSuccessor = false
    @State private var leaving = false
    @State private var problem: String?
    /// The name whose keyboard is up.
    @State private var naming: Library.Named?
    /// The page open, if one is.
    @State private var page: Page?
    enum Page: Hashable { case people, devices, sources, interval }
    @AppStorage(Library.showsSyncActivity) private var showsSyncActivity = false
    /// The focused row, whose explanation shows under the picture.
    @FocusState private var focus: SettingsRow?

    private var me: Member? { library.members.first(where: \.you) }
    private var others: [Member] { library.members.filter { !$0.you } }
    /// The system's rows' text (and headings') inset in its plate, wider
    /// than a form's.
    static let rowInsets = EdgeInsets(top: 0, leading: 30, bottom: 0, trailing: 30)

    /// The founder's only device: leaving takes the founder with it, so it
    /// hands the library over first, or, if no one else is in it, ends it.
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
                pageRow("People", library.members.count, .people)
                    .settingsRow(.people, $focus)
                pageRow("Your Devices", library.devices.count, .devices)
                    .settingsRow(.devices, $focus)
            } header: {
                Text("Sharing").bold()
            }
            .listRowInsets(Self.rowInsets)
            Section {
                pageRow("Sources", library.sources.filter { !$0.managed }.count, .sources)
                    .settingsRow(.sources, $focus)
                Button("Refresh Library") {
                    Task { await library.refresh() }
                }
                .disabled(library.activity != nil || leaving)
                .settingsRow(.refresh, $focus)
                Button { page = .interval } label: {
                    ValueLabel(title: "Look for New Videos", opens: true, value: Library.crawlChoices.first { $0.hours == library.crawlEvery }?.name ?? "")
                }
                .settingsRow(.interval, $focus)
                // A toggle's row, its state as its value, as the system's.
                Button { showsSyncActivity.toggle() } label: {
                    ValueLabel(title: "Show Sync Activity", value: showsSyncActivity ? "On" : "Off")
                }
                .accessibilityAddTraits(.isToggle)
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
        .navigationDestination(item: $page) { page in
            switch page {
            case .people: PeoplePage()
            case .devices: DevicesPage()
            case .sources: SourcesPage()
            case .interval: IntervalPage()
            }
        }
        #if DEBUG
        // `CINEMATHEQUE_PAGE`: a page to open (adding, from its list's).
        .onAppear {
            switch Launch.page {
            case "people", "add-someone": page = .people
            case "devices", "add-device": page = .devices
            case "sources": page = .sources
            default: break
            }
        }
        // Once the library's people are read.
        .task(id: me?.key) {
            guard me != nil, let how = Launch.leave else { return }
            askToLeave()
            guard how == "confirm" else { return }
            try? await Task.sleep(for: .seconds(1))
            if choosingSuccessor, let first = others.first {
                choosingSuccessor = false
                leave(successor: first.key)
            } else if confirmingLeave {
                confirmingLeave = false
                if foundersOnly { end() } else { leave(successor: nil) }
            }
        }
        #endif
        // Hard to undo, so asked first.
        .alert(foundersOnly ? "End This Library?" : "Leave This Library?", isPresented: $confirmingLeave) {
            Button(foundersOnly ? "Leave and End It" : "Leave", role: .destructive) { if foundersOnly { end() } else { leave(successor: nil) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(foundersOnly
                ? "No one else is in this library, so once this Apple TV leaves, it's gone for good. Its videos stay where they are."
                : "This Apple TV leaves the library, and your other devices no longer list it. To come back, pair it again.")
        }
        // The founder's only device leaving: someone takes over first.
        .confirmationDialog("Who takes over the library?", isPresented: $choosingSuccessor, titleVisibility: .visible) {
            ForEach(others) { member in
                Button(member.name ?? "Someone Unnamed") { leave(successor: member.key) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You founded this library, and this Apple TV is your only device in it, so someone takes over as its founder before it leaves.")
        }
    }

    /// A row opening a page, with how many it lists.
    private func pageRow(_ title: String, _ count: Int, _ opens: Page) -> some View {
        Button { page = opens } label: {
            ValueLabel(title: title, opens: true, value: count.formatted())
        }
    }

    /// A name: pressing it brings up the full-screen keyboard at once,
    /// holding the name (an unseen UIKit field's: a SwiftUI field in a row
    /// draws a plate of its own in the row's and crowds the name); saved as
    /// it's submitted (a blank one ignored), and Back leaves it as it was.
    private func nameRow(_ title: String, _ name: String?, _ which: Library.Named) -> some View {
        Button { naming = which } label: {
            // A chevron, as the system's Name row has, though a keyboard opens.
            ValueLabel(title: title, opens: true, value: name ?? "Unnamed")
        }
        .background {
            KeyboardField(title: title, text: name ?? "", typing: Binding(get: { naming == which }, set: { if !$0 { naming = nil } })) {
                library.setName(which, $0)
            }
            .unseen()
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
        }
    }
}

/// A row of Settings, by what it does.
enum SettingsRow: Hashable {
    case device, person, people, devices, sources, refresh, interval, activity, leave

    /// Shown under the picture as the row's focused, and read by VoiceOver
    /// as its hint, since what's shown only on focus it never reaches.
    var explanation: String {
        switch self {
        case .device: "A name your other devices know this Apple TV by, so you can tell it apart from them."
        case .person: "Your name, so others in the library know whose devices are whose."
        case .people: "Share the library with the people you watch with: each keeps their own progress and watchlist. Add someone, or remove them."
        case .devices: "Add your other devices, such as an Apple TV in another room, so they share your progress and watchlist; rename or remove them."
        case .sources: "The servers that hold your videos, such as a NAS. Add one by its address, or remove one."
        case .refresh: "Added videos to a server or folder? Refresh to see them now, rather than waiting for the next look."
        case .interval: "Look more often to see new videos sooner, or less often to let a NAS's disks rest; each look wakes them."
        case .activity: "Shows when your devices catch up with one another, to check that a change made elsewhere has arrived."
        case .leave: "Takes this Apple TV out of the library, to join another or give it to someone. Its videos stay where they are."
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

/// A row's title and value, as tvOS's Settings draws them: side by side,
/// the value giving way first, or at accessibility text sizes, the value
/// under the title; and for a row opening something, a chevron (measured
/// against the system's: 18 by 32 points, 32 after the value and 36 short
/// of the plate's edge, scaling with the text). A path's title (`path`, a
/// source's server and folders) gives way instead, its middle folders
/// first.
struct ValueLabel: View {
    let title: String
    var path: [String]? = nil
    var opens = false
    let value: String
    @Environment(\.dynamicTypeSize) private var size
    @ScaledMetric(relativeTo: .headline) private var chevron = 39.0

    var body: some View {
        HStack(spacing: 23) {
            if size.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    if let path { PathText(parts: path) } else { Text(title) }
                    Text(value).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            } else if let path {
                PathText(parts: path)
                Spacer(minLength: 0)
                Text(value)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                Text(title)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                // On one line, as the system's values, so rows keep one height.
                Text(value)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            if opens {
                Image(systemName: "chevron.forward")
                    .font(.system(size: chevron, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 3)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A path's parts ("sulaco › Video › TV Shows") as wide as fits: whole,
/// else its middle parts collapsed into an ellipsis, one more at a time
/// ("sulaco › … › TV Shows"), its first and last kept, as they say which
/// server and which folder; at the last, cut short in the middle.
private struct PathText: View {
    let parts: [String]

    /// Each way to show it, widest first.
    private var forms: [String] {
        guard parts.count > 2 else { return [parts.joined(separator: " › ")] }
        return [parts.joined(separator: " › ")] + (1...(parts.count - 2)).map { hidden in
            ([parts[0], "…"] + parts.suffix(parts.count - 1 - hidden)).joined(separator: " › ")
        }
    }

    var body: some View {
        let forms = forms
        ViewThatFits(in: .horizontal) {
            ForEach(forms.dropLast(), id: \.self) { Text($0).lineLimit(1).fixedSize() }
            Text(forms.last ?? "").lineLimit(1).truncationMode(.middle)
        }
        .accessibilityLabel(parts.joined(separator: ", "))
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
        SettingsPage(title: "Look for New Videos", explanation: SettingsRow.interval.explanation) {
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
/// a subpage's title.
struct SettingsPage<List: View>: View {
    /// A subpage's title, at the top in the middle, as the system's are
    /// (SwiftUI's navigation title sits lower and pushes the list down).
    var title: String?
    let explanation: String
    @ViewBuilder let list: List

    private static var left: CGFloat { 1060 / 1920 }
    private static var listWidth: CGFloat { 780 / 1920 }
    /// The picture, smaller and higher at accessibility text sizes, as the
    /// system's.
    private var pictureWidth: CGFloat { (size.isAccessibilitySize ? 316 : 540) / 1920 }
    private var pictureCenter: CGFloat { (size.isAccessibilitySize ? 344 : 506) / 1080 }
    @Environment(\.dynamicTypeSize) private var size
    /// A row's line of text, of which, at accessibility sizes, a row is
    /// three, as the system's (200 points to its 66.7).
    @ScaledMetric(relativeTo: .headline) private var line = 46.0
    private static var explanationWidth: CGFloat { 768 / 1920 }
    /// The explanation's box, low under the picture, or at accessibility
    /// text sizes, from under the smaller picture, so larger text fits.
    private var explanationTop: CGFloat { (size.isAccessibilitySize ? 500 : 850) / 1080 }
    private var explanationHeight: CGFloat { (size.isAccessibilitySize ? 520 : 180) / 1080 }
    private static var titleCenter: CGFloat { 90.5 / 1080 }
    /// The list's height to spare, while it's shorter than the screen.
    @State private var spare: CGFloat = 0

    var body: some View {
        GeometryReader { screen in
            let width = screen.size.width
            HStack(spacing: 0) {
                GeometryReader { pane in
                    Image("SettingsIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 24))
                        .frame(width: width * pictureWidth)
                        .position(x: pane.size.width / 2, y: pane.size.height * pictureCenter)
                        .accessibilityHidden(true)
                    Text(explanation)
                        // VoiceOver reads it as each row's hint instead.
                        .accessibilityHidden(true)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                        .animation(.default, value: explanation)
                        .frame(width: width * Self.explanationWidth, height: pane.size.height * explanationHeight, alignment: .top)
                        .position(x: pane.size.width / 2, y: pane.size.height * (explanationTop + explanationHeight / 2))
                }
                // The whole height, as the system's.
                .ignoresSafeArea(edges: .vertical)
                .frame(width: width * Self.left)
                list
                    .formStyle(.grouped)
                    // Centered on the screen's height while it fits, as
                    // the system's, from its top once it scrolls: its
                    // spare height split above and below it.
                    .background { SpareHeight(spare: $spare) }
                    .contentMargins(.vertical, spare / 2, for: .scrollContent)
                    .font(.headline)
                    .environment(\.defaultMinListRowHeight, size.isAccessibilitySize ? 3 * line : 66)
                    .frame(width: width * Self.listWidth)
                Spacer(minLength: 0)
            }
        }
        .ignoresSafeArea(edges: .horizontal)
        .overlay {
            if let title {
                GeometryReader { screen in
                    Text(title)
                        .font(.title2.bold())
                        .foregroundStyle(.tertiary)
                        .accessibilityAddTraits(.isHeader)
                        .position(x: screen.size.width / 2, y: screen.size.height * Self.titleCenter)
                }
                .ignoresSafeArea()
            }
        }
    }
}

extension KeyboardField {
    /// Out of sight, a point behind what's pressed, as only its keyboard
    /// shows: clipped, as tvOS's fields keep a size of their own, whose
    /// plate would show through the row's.
    func unseen() -> some View {
        frame(width: 1, height: 1).clipped().opacity(0.01).accessibilityHidden(true)
    }
}

/// A UIKit text field, unseen, whose keyboard comes up full screen as
/// `typing` turns on, holding `text`; `submit` takes what's typed when it's
/// submitted, not when it's dismissed. Its `keyboard` is digits for a
/// pairing code, or for an address, one without capitals or corrections.
struct KeyboardField: UIViewRepresentable {
    let title: String
    let text: String
    var keyboard: UIKeyboardType = .default
    @Binding var typing: Bool
    let submit: (String) -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.returnKeyType = .done
        field.keyboardType = keyboard
        if keyboard != .default {
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
        }
        // No plate of its own, which would show through the row's.
        field.borderStyle = .none
        field.backgroundColor = .clear
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

/// How much shorter a form's content is than the form, read from the
/// UIKit scroll view under it: a form keeps no scroll anchor, and a list
/// that doesn't scroll never calls `onScrollGeometryChange`'s action, so
/// SwiftUI can't tell. Behind the form, so the scroll view it finds is the
/// one around its frame (the form's runs the screen's height, past the
/// safe area this keeps to).
private struct SpareHeight: UIViewRepresentable {
    @Binding var spare: CGFloat

    func makeUIView(context: Context) -> Probe { Probe { spare = $0 } }
    func updateUIView(_ view: Probe, context: Context) {}

    final class Probe: UIView {
        private let report: (CGFloat) -> Void
        private var observations: [NSKeyValueObservation] = []

        init(report: @escaping (CGFloat) -> Void) {
            self.report = report
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard observations.isEmpty, let scroll = formScrollView() else { return }
            // UIKit's properties change on the main thread, so they're
            // observed there.
            observations = [
                scroll.observe(\.contentSize, options: .initial) { [weak self] view, _ in MainActor.assumeIsolated { self?.measure(view) } },
                scroll.observe(\.bounds) { [weak self] view, _ in MainActor.assumeIsolated { self?.measure(view) } },
            ]
        }

        /// Reports the spare height, after the layout that changed it.
        private func measure(_ view: UIScrollView) {
            // Within the safe area, not the margins this sets.
            let spare = max(0, view.bounds.height - view.safeAreaInsets.top - view.safeAreaInsets.bottom - view.contentSize.height)
            DispatchQueue.main.async { [weak self] in self?.report(spare) }
        }

        /// The innermost scroll view around this one, among its ancestors'
        /// descendants.
        private func formScrollView() -> UIScrollView? {
            guard let window else { return nil }
            let mine = convert(bounds, to: window)
            var ancestor = superview
            while let view = ancestor {
                if let found = Self.scrollViews(in: view).filter({ $0.convert($0.bounds, to: window).contains(mine) }).min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) { return found }
                ancestor = view.superview
            }
            return nil
        }

        private static func scrollViews(in view: UIView) -> [UIScrollView] {
            view.subviews.flatMap { ($0 as? UIScrollView).map { [$0] } ?? scrollViews(in: $0) }
        }
    }
}
#endif
