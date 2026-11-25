#if os(tvOS)
import SwiftUI

// The Apple TV's Settings' shell, as tvOS's Settings app lays out its
// pages; the pages are shared with the iPhone (SettingsPages.swift).

extension SettingsView {
    /// The system's rows' text (and headings') inset in its plate, wider
    /// than a form's.
    static let rowInsets = EdgeInsets(top: 0, leading: 30, bottom: 0, trailing: 30)
}

/// What the focused row of a page does, set by its `explained` rows.
@MainActor @Observable
final class Explanation {
    var text: String?
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

/// A setting's choices, as tvOS's Settings lists them: the current one
/// checked and focused first; choosing one sets it and goes back.
struct ChoicePage<Value: Hashable>: View {
    let title: String
    let explanation: String
    let choices: [(name: String, value: Value)]
    @Binding var selection: Value
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Value?

    var body: some View {
        SettingsPage(title: title, explanation: explanation) {
            Form {
                Section {
                    ForEach(choices, id: \.value) { choice in
                        Button {
                            selection = choice.value
                            dismiss()
                        } label: {
                            LabeledContent(choice.name) {
                                if choice.value == selection { Image(systemName: "checkmark") }
                            }
                        }
                        .focused($focus, equals: choice.value)
                        .accessibilityAddTraits(choice.value == selection ? .isSelected : [])
                    }
                }
                .listRowInsets(SettingsView.rowInsets)
            }
            .scrollClipDisabled()
            .defaultFocus($focus, selection)
        }
    }
}

/// A page laid out as tvOS's Settings lays its out, by its proportions of
/// the screen (measured on its 1920 by 1080 points): the app's icon a
/// little below the middle of the left 55%, and low under it, 40% of the
/// screen wide, what the focused row does; the list from there to 4% short
/// of the right edge, in the system's row text size (`.headline`), under
/// a subpage's title. What it explains is its focused row's, else
/// `explanation`.
struct SettingsPage<List: View>: View {
    /// A subpage's title, at the top in the middle, as the system's are
    /// (SwiftUI's navigation title sits lower and pushes the list down).
    var title: String?
    var explanation = ""
    @ViewBuilder let list: List
    @State private var focused = Explanation()

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
                    let explanation = focused.text ?? self.explanation
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
                    .environment(focused)
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
/// submitted, not when it's dismissed; its keyboard is `input`'s.
struct KeyboardField: UIViewRepresentable {
    let title: String
    let text: String
    var input = TextInput.name
    @Binding var typing: Bool
    let submit: (String) -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.returnKeyType = .done
        field.keyboardType = switch input {
        case .name, .verbatim: .default
        case .address: .URL
        case .code: .numberPad
        }
        if input != .name {
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
