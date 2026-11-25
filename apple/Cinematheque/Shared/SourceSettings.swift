import SwiftUI

// A source's settings, as the Mac's sheet and the iPhone's and Apple TV's
// pages show them.

/// Where a source's files' quality comes from, and the name, if named; a
/// newer version's setting kept unless another is chosen. `submit` saves a
/// name typed.
struct SourceQualityPicker: View {
    @Binding var from: Source.QualityFrom
    @Binding var name: String
    var submit: () -> Void = {}

    private var choices: [(name: String, value: Source.QualityFrom)] {
        [("From Names and Folders", .path), ("Named", .named)] + (from == .unknown ? [("Set by a Newer Version", .unknown)] : [])
    }

    var body: some View {
        #if os(macOS)
        Picker("Quality", selection: $from) {
            ForEach(choices, id: \.value) { Text($0.name).tag($0.value) }
        }
        // Only for a name, as Settings show a choice's details.
        if from == .named {
            TextField("Name", text: $name, prompt: Text("4K HDR"))
                .onSubmit(submit)
        }
        #else
        ChoiceRow(title: "Quality", choices: choices, selection: $from)
            .explained()
        if from == .named {
            TextRow(title: "Name", text: $name, prompt: "4K HDR", input: .verbatim, submit: submit)
                .explained()
        }
        #endif
    }
}

/// A source's unavailable folders (as a drive unplugged leaves them), each
/// with its videos removable (on the Apple TV, by pressing it); nothing if
/// it has none.
struct UnavailableFolders: View {
    let source: Source
    @Environment(Library.self) private var library

    private static let header = "Unavailable"
    private static let footer = "Folders that are empty now, as when a drive is unplugged. Their videos stay, dimmed, so nothing's lost while it's away; remove them if it's gone for good. After a year, they go on their own."

    var body: some View {
        if !source.unavailable.isEmpty {
            #if os(macOS)
            Section { folders } header: { Text(Self.header) } footer: { Text(Self.footer) }
            #else
            SettingsSection(header: Self.header, footer: Self.footer) { folders }
            #endif
        }
    }

    private var folders: some View {
        ForEach(source.unavailable, id: \.dir) { gone in
            let since = "Since \(gone.date.formatted(date: .abbreviated, time: .omitted))"
            #if os(macOS)
            LabeledContent {
                Button("Remove Videos", systemImage: "minus.circle") { library.removeUnavailable(source.id, gone.dir) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove its videos; they return if the folder does")
            } label: {
                Label(gone.name, systemImage: "externaldrive.badge.questionmark")
                Text(since)
            }
            #elseif os(tvOS)
            Button { library.removeUnavailable(source.id, gone.dir) } label: { RowLabel(title: gone.name, value: since) }
                .explained("Press to remove its videos; they return if the folder does.")
            #else
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(gone.name)
                    Text(since).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove Videos", role: .destructive) { library.removeUnavailable(source.id, gone.dir) }
                    .buttonStyle(.borderless)
            }
            #endif
        }
    }
}
