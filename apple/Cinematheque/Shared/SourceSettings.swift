#if os(macOS) || os(iOS)
import SwiftUI

// A source's settings, as the Mac's sheet and the iPhone's pages show them;
// the Apple TV leaves them to those.

/// Where a source's files' quality comes from, and the name, if named; a
/// newer version's setting kept unless another is chosen. `submit` saves a
/// name typed.
struct SourceQualityPicker: View {
    @Binding var from: Source.QualityFrom
    @Binding var name: String
    var submit: () -> Void = {}

    var body: some View {
        Picker("Quality", selection: $from) {
            Text("From Names and Folders").tag(Source.QualityFrom.path)
            Text("Named").tag(Source.QualityFrom.named)
            if from == .unknown { Text("Set by a Newer Version").tag(Source.QualityFrom.unknown) }
        }
        // Only for a name, as Settings show a choice's details.
        if from == .named {
            #if os(iOS)
            LabeledContent("Name") {
                TextField("Name", text: $name, prompt: Text("4K HDR"))
                    .multilineTextAlignment(.trailing)
                    .onSubmit(submit)
            }
            #else
            TextField("Name", text: $name, prompt: Text("4K HDR"))
                .onSubmit(submit)
            #endif
        }
    }
}

/// A source's unavailable folders (as a drive unplugged leaves them), each
/// with its videos removable; nothing if it has none.
struct UnavailableFolders: View {
    let source: Source
    @Environment(Library.self) private var library

    var body: some View {
        if !source.unavailable.isEmpty {
            Section {
                ForEach(source.unavailable, id: \.dir) { gone in
                    let since = Text("Since \(gone.date.formatted(date: .abbreviated, time: .omitted))")
                    #if os(macOS)
                    LabeledContent {
                        Button("Remove Videos", systemImage: "minus.circle") { library.removeUnavailable(source.id, gone.dir) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove its videos; they return if the folder does")
                    } label: {
                        Label(gone.name, systemImage: "externaldrive.badge.questionmark")
                        since
                    }
                    #else
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(gone.name)
                            since.font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove Videos", role: .destructive) { library.removeUnavailable(source.id, gone.dir) }
                            .buttonStyle(.borderless)
                    }
                    #endif
                }
            } header: {
                Text("Unavailable")
            } footer: {
                Text("Folders that are empty now, as when a drive is unplugged. Their videos stay, dimmed, so nothing's lost while it's away; remove them if it's gone for good. After a year, they go on their own.")
            }
        }
    }
}
#endif
