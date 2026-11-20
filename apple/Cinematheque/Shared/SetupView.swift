import SwiftUI

/// The first run, on every platform: being yourself here, by pairingAsYours this
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
/// wrong codes, asking for a new one. Pairing (`join` false) brings this
/// device its person and the library; joining, the library, and membership.
struct OfferedCode: View {
    var size: CGFloat = 140
    @Environment(Library.self) private var library
    @State private var state: Library.Pairing?
    /// Counts offers, each with a new code.
    @State private var offers = 0

    var body: some View {
        VStack(spacing: size / 4) {
            if let code = state?.code {
                // As the other device's field takes it, a digit a box.
                CodeBoxes(digits: code, size: size)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Pairing code \(code.map(String.init).joined(separator: " "))")
                HStack {
                    ProgressView()
                        #if os(macOS)
                        .controlSize(.small)
                        #endif
                    Text("Waiting to be added…")
                        .foregroundStyle(.secondary)
                }
            } else if state?.closed == true {
                Text("That was too many wrong codes.").foregroundStyle(.secondary)
                Button("Show a New Code") { offers += 1 }
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: offers) {
            state = library.offerPairing()
            #if DEBUG
            Launch.note(code: state?.code)
            #endif
            // Until paired or stopped.
            while !Task.isCancelled, state?.code != nil {
                try? await Task.sleep(for: .seconds(1))
                if let checked = library.checkPairing() { state = checked }
            }
        }
    }
}

/// A pairing code's six digits, a squircle each, in two groups of three
/// (as codes are read): filled as far as `digits` goes, the rest empty,
/// so the boxes show how long a code is before it's typed. The box the
/// next digit goes in is ringed if `caret`.
struct CodeBoxes: View {
    static let length = 6
    let digits: String
    /// The digits' point size; the boxes scale with it.
    var size: CGFloat
    var caret = false

    var body: some View {
        HStack(spacing: size * 0.4) {
            group(0..<3)
            group(3..<6)
        }
    }

    private func group(_ range: Range<Int>) -> some View {
        HStack(spacing: size * 0.14) {
            ForEach(range, id: \.self) { box($0) }
        }
    }

    private func box(_ i: Int) -> some View {
        let digit = i < digits.count ? String(digits[digits.index(digits.startIndex, offsetBy: i)]) : ""
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        return Text(digit)
            .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
            .frame(width: size * 1.1, height: size * 1.45)
            .background(.quaternary, in: shape)
            .overlay {
                if caret, i == min(digits.count, Self.length - 1) {
                    shape.strokeBorder(Color.accentColor, lineWidth: max(2, size / 12))
                }
            }
    }
}

#if !os(tvOS)
private struct SetupForm: View {
    @Environment(Library.self) private var library
    /// Whether this Mac shows a code, to be added to a library.
    @State private var offering = false

    var body: some View {
        Form {
            Section {
                if let device = library.removedBy {
                    Label("This Mac was removed from its library (as \(device) said). Join it again to use the library, or start another.", systemImage: "exclamationmark.triangle.fill")
                }
                Text("A library of the movies and series your household keeps, shared among your devices.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Welcome to Cinematheque").font(.largeTitle.weight(.semibold))
            }
            Section {
                if offering {
                    OfferedCode(size: 44)
                } else {
                    Button("Join a Library") { offering = true }
                }
            } header: {
                Text("Join a library")
            } footer: {
                Text("This Mac shows a code. On a device in the library, yours or that of someone who shares it, enter it in Cinematheque's Settings > Devices, under New Devices.")
            }
            Section {
                Button("Create Library") {
                    offering = false
                    library.found()
                }
            } header: {
                Text("Start a library")
            } footer: {
                Text("You'll found it, and can add the people you share it with.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        #if DEBUG
        // `CINEMATHEQUE_TAB` names a step, as on tvOS: `join`, to show a code.
        .onAppear { if Launch.tab == "join" { offering = true } }
        #endif
    }
}
#endif
