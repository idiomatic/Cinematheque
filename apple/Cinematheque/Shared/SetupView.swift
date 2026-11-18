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
}

/// A new device's offer to pair, until paired (the app then leaves setup):
/// its code, to enter on a member's device, and waiting; or, after too many
/// wrong codes, asking for a new one. Linking (`join` false) brings this
/// device its user and the library; joining, the library, and membership.
struct OfferedCode: View {
    let join: Bool
    var size: CGFloat = 140
    @Environment(Library.self) private var library
    @State private var state: Library.Pairing?
    /// Counts offers, each with a new code.
    @State private var offers = 0

    var body: some View {
        VStack(spacing: size / 4) {
            if let code = state?.code {
                // In two groups of three, to read at a distance.
                Text(code.prefix(3) + " " + code.suffix(3))
                    .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                    .padding(.horizontal, size * 0.4)
                    .padding(.vertical, size / 7)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: size / 6))
                HStack {
                    ProgressView()
                        #if os(macOS)
                        .controlSize(.small)
                        #endif
                    Text(join ? "Waiting to be let in…" : "Waiting for your other device…")
                        .foregroundStyle(.secondary)
                }
            } else if state?.closed == true {
                Text("That was too many wrong codes.").foregroundStyle(.secondary)
                Button("Show a New Code") { offers += 1 }
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: offers) {
            state = library.offerPairing(join: join)
            // Until paired or stopped.
            while !Task.isCancelled, state?.code != nil {
                try? await Task.sleep(for: .seconds(1))
                if let checked = library.checkPairing() { state = checked }
            }
        }
    }
}

#if !os(tvOS)
private struct SetupForm: View {
    @Environment(Library.self) private var library
    /// The offer showing its code, if any: to join (true) or to link.
    @State private var joining: Bool?

    var body: some View {
        Form {
            Section {
                Text("A library of the movies and shows your household keeps, shared among your devices.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Welcome to Cinematheque").font(.largeTitle.weight(.semibold))
            }
            Section {
                if joining == false {
                    OfferedCode(join: false, size: 44)
                } else {
                    Button("Pair with Your Other Device") { joining = false }
                }
            } header: {
                Text("Another of your devices?")
            } footer: {
                Text("This Mac shows a code. On a device where you use Cinematheque, enter it in Settings › People & Devices, under New Devices, to be yourself here, with your playheads and watchlist.")
            }
            Section {
                Button("Create Library") {
                    joining = nil
                    library.found(nil)
                }
            } header: {
                Text("Start a library")
            } footer: {
                Text("You'll found it, and can add the people you share it with.")
            }
            Section {
                if joining == true {
                    OfferedCode(join: true, size: 44)
                } else {
                    Button("Ask to Join") { joining = true }
                }
            } header: {
                Text("Join someone's library")
            } footer: {
                Text("This Mac shows a code. Someone who shares the library enters it in Cinematheque's Settings › People & Devices, under New Devices, to let you in.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }
}
#endif
