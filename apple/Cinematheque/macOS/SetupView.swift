#if os(macOS)
import SwiftUI

/// The first run: creating a library, joining one, or linking this device
/// to its user's others first.
struct SetupView: View {
    @Environment(Library.self) private var library
    @State private var founder = ""
    @State private var secret = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Cinematheque").font(.largeTitle.weight(.semibold))
                    Text("A library of the movies and shows your household keeps, shared among your devices. Start one, or join one someone has started.")
                        .foregroundStyle(.secondary)
                }
                GroupBox("Start a library") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("You'll found it, and can add the people you share it with.")
                            .foregroundStyle(.secondary)
                        Button("Create Library") { library.found(nil) }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                GroupBox("Join a library") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paste its founder's key. Then a member adds you, by your key:")
                            .foregroundStyle(.secondary)
                        KeyField(key: library.status?.user ?? "")
                        HStack {
                            TextField("Founder's key", text: $founder)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospaced())
                            Button("Join") { library.found(founder) }
                                .disabled(founder.trimmingCharacters(in: .whitespacesAndNewlines).count != 64)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                GroupBox("Another of your devices") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("To be yourself here, with your playheads and watchlist, first paste your secret from a device you already use (Settings › This Device there), then join.")
                            .foregroundStyle(.secondary)
                        HStack {
                            SecureField("Your secret", text: $secret)
                                .textFieldStyle(.roundedBorder)
                            Button("Link") {
                                library.link(secret)
                                secret = ""
                            }
                            .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).count != 64)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
            .padding(32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A key, selectable, with a button to copy it.
struct KeyField: View {
    let key: String

    var body: some View {
        HStack {
            Text(key)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
    }
}
#endif
