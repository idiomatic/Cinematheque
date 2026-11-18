import SwiftUI

/// The first run, on every platform: being yourself here, by linking this
/// device to another of yours (first, if so), then starting a library or
/// joining one. On tvOS, as tvOS apps set up: a few large choices, each
/// a screen of its own (`SetupFlow`); elsewhere, one form.
struct SetupView: View {
    var body: some View {
        #if os(tvOS)
        SetupFlow()
        #else
        SetupForm()
        #endif
    }

    static func isKey(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count == 64
    }
}

#if !os(tvOS)
private struct SetupForm: View {
    @Environment(Library.self) private var library
    @State private var secret = ""
    @State private var founder = ""

    var body: some View {
        Form {
            Section {
                Text("A library of the movies and shows your household keeps, shared among your devices.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Welcome to Cinematheque").font(.largeTitle.weight(.semibold))
            }
            Section {
                if linked {
                    Label("This device is linked to you.", systemImage: "checkmark.circle.fill")
                } else {
                    SecureField("Your secret", text: $secret)
                    Button("Link") {
                        library.link(secret.trimmingCharacters(in: .whitespacesAndNewlines))
                        secret = ""
                    }
                    .disabled(!SetupView.isKey(secret))
                }
            } header: {
                Text("Another of your devices?")
            } footer: {
                Text("To be yourself here, with your playheads and watchlist, enter your secret from a device you already use (in Cinematheque's Settings there, under People & Devices › Add a Device).")
            }
            Section {
                Button("Create Library") { library.found(nil) }
            } header: {
                Text("Start a library")
            } footer: {
                Text("You'll found it, and can add the people you share it with.")
            }
            Section {
                TextField("Founder's key", text: $founder)
                Button("Join") { library.found(founder.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .disabled(!SetupView.isKey(founder))
                if !linked {
                    LabeledContent("Your key") { KeyField(key: library.status?.user ?? "") }
                }
            } header: {
                Text("Join a library")
            } footer: {
                Text(linked
                    ? "Enter its founder's key, shown in Settings › People & Devices › Add a Device on your other device."
                    : "Enter its founder's key; then a member adds you, by your key.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    /// Whether this device acts as a user other than its own (linked).
    private var linked: Bool { library.linked }
}
#endif

/// A key, selectable, with a button to copy it where there's a pasteboard.
struct KeyField: View {
    let key: String

    var body: some View {
        HStack {
            Text(key)
                .font(.caption.monospaced())
                #if os(macOS)
                .textSelection(.enabled)
                #endif
                .lineLimit(1)
                .truncationMode(.middle)
            #if os(macOS)
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            #endif
        }
    }
}
