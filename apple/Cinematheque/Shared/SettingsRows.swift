#if os(iOS) || os(tvOS)
import SwiftUI

// What the iPhone's and Apple TV's Settings pages are made of, each drawn
// as its platform's own: on the iPhone, iOS's grouped forms; on the Apple
// TV, tvOS's Settings app's (`SettingsPage`), where a row is pressed rather
// than typed into, and explains itself beside the list as it's focused.

/// A page of Settings: on the iPhone, a grouped form under an inline
/// title; on the Apple TV, the form in tvOS's Settings' layout. The root
/// has no title of its own.
struct SettingsForm<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        #if os(tvOS)
        SettingsPage(title: title) {
            Form { content }
                // Narrowed, it would clip a focused row, which grows past its edges.
                .scrollClipDisabled()
                // `ValueLabel` draws the system's chevron; a link's own is smaller.
                .navigationLinkIndicatorVisibility(.hidden)
        }
        #else
        if let title {
            Form { content }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            Form { content }
        }
        #endif
    }
}

/// A section of Settings. Its footer says what its rows are for: under it
/// on the iPhone; on the Apple TV, as the explanation of each row without
/// one of its own. A problem shows in its place, in red on the iPhone.
struct SettingsSection<Content: View>: View {
    var header: String?
    var footer: String?
    var problem: String?
    @ViewBuilder let content: Content

    var body: some View {
        #if os(tvOS)
        Section {
            content.environment(\.sectionNote, problem ?? footer)
        } header: {
            if let header { Text(header).bold() }
        }
        .listRowInsets(SettingsView.rowInsets)
        #else
        Section {
            content
        } header: {
            if let header { Text(header) }
        } footer: {
            if let problem { Text(problem).foregroundStyle(.red) } else if let footer { Text(footer) }
        }
        #endif
    }
}

extension EnvironmentValues {
    /// A section's footer, its rows' explanation on the Apple TV.
    @Entry var sectionNote: String?
}

extension View {
    /// A row of Settings: on the Apple TV, `explanation` (else its
    /// section's footer) shows beside the list while it's focused, and is
    /// its VoiceOver hint, as VoiceOver doesn't reach what shows only on
    /// focus.
    func explained(_ explanation: String? = nil) -> some View {
        modifier(Explained(own: explanation))
    }
}

private struct Explained: ViewModifier {
    let own: String?
    @Environment(\.sectionNote) private var note
    #if os(tvOS)
    @Environment(Explanation.self) private var shown: Explanation?
    @FocusState private var focused: Bool
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        let text = own ?? note ?? ""
        content
            .focused($focused)
            .accessibilityHint(text)
            .onChange(of: focused) { if focused { shown?.text = text } }
            .onChange(of: text) { if focused { shown?.text = text } }
        #else
        content
        #endif
    }
}

/// A row's title and value: on the Apple TV, as its Settings draws them,
/// with a chevron if it `opens` something.
struct RowLabel: View {
    let title: String
    var value = ""
    var opens = false

    var body: some View {
        #if os(tvOS)
        ValueLabel(title: title, opens: opens, value: value)
        #else
        LabeledContent(title, value: value)
        #endif
    }
}

/// A fact, shown: focusable on the Apple TV, as its Settings' are, so it
/// explains itself.
struct ValueRow: View {
    let title: String
    let value: String

    var body: some View {
        #if os(tvOS)
        Button {} label: { RowLabel(title: title, value: value) }
        #else
        RowLabel(title: title, value: value)
        #endif
    }
}

/// A row opening a page, with what it holds as its value.
struct SettingsLink<Destination: View>: View {
    let title: String
    let value: String
    @ViewBuilder let destination: Destination

    var body: some View {
        NavigationLink { destination } label: { RowLabel(title: title, value: value, opens: true) }
    }
}

/// A setting chosen among a few: on the iPhone, a menu; on the Apple TV, a
/// page of them, as its Settings lists a setting's.
struct ChoiceRow<Value: Hashable>: View {
    let title: String
    let choices: [(name: String, value: Value)]
    @Binding var selection: Value
    @Environment(\.sectionNote) private var note

    var body: some View {
        #if os(tvOS)
        NavigationLink {
            ChoicePage(title: title, explanation: note ?? "", choices: choices, selection: $selection)
        } label: {
            RowLabel(title: title, value: choices.first { $0.value == selection }?.name ?? "", opens: true)
        }
        #else
        Picker(title, selection: $selection) {
            ForEach(choices, id: \.value) { Text($0.name).tag($0.value) }
        }
        #endif
    }
}

/// How what's typed is taken: a name, as written; text without capitals
/// or corrections; a web address; or a pairing code's digits.
enum TextInput {
    case name, verbatim, address, code
}

/// Text typed in place, on the iPhone, after its title, `submit` called as
/// it's submitted or left; on the Apple TV, the row pressed brings up the
/// full-screen keyboard holding it (an unseen UIKit field's: a SwiftUI
/// field in a row draws a plate of its own in the row's and crowds the
/// title), `submit` called as it's submitted, Back leaving it as it was.
struct TextRow: View {
    let title: String
    @Binding var text: String
    var prompt = "None"
    var input = TextInput.name
    var submit: () -> Void = {}
    #if os(tvOS)
    @State private var typing = false
    #else
    @FocusState private var typing: Bool
    #endif

    var body: some View {
        #if os(tvOS)
        Button { typing = true } label: {
            // A chevron, as the system's Name row has, though a keyboard opens.
            RowLabel(title: title, value: text.isEmpty ? prompt : text, opens: true)
        }
        .background {
            KeyboardField(title: title, text: text, input: input, typing: $typing) {
                text = $0
                submit()
            }
            .unseen()
        }
        #else
        LabeledContent(title) {
            TextField(title, text: $text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .typed(as: input)
                .focused($typing)
                .submitLabel(.done)
                .onSubmit(submit)
        }
        .onChange(of: typing) { if !typing { submit() } }
        #endif
    }
}

#if os(iOS)
extension View {
    /// The keyboard and corrections for what's typed.
    func typed(as input: TextInput) -> some View {
        let keyboard: UIKeyboardType = switch input {
        case .name, .verbatim: .default
        case .address: .URL
        case .code: .numberPad
        }
        return keyboardType(keyboard)
            .textContentType(keyboard == .URL ? .URL : nil)
            .autocorrectionDisabled(input != .name)
            .textInputAutocapitalization(input == .name ? .words : .never)
    }
}
#endif

/// A name, typed in place: saved as it's submitted, a blank one put back
/// as it was.
struct NameField: View {
    let title: String
    let name: String?
    let save: (String) -> Void
    @State private var typed = ""

    var body: some View {
        TextRow(title: title, text: $typed, prompt: "Unnamed", submit: commit)
            .onAppear { typed = name ?? "" }
            .onChange(of: name) { typed = name ?? "" }
    }

    private func commit() {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == name { typed = name ?? "" } else { save(trimmed) }
    }
}
#endif
