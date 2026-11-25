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
            // Until paired or stopped.
            while !Task.isCancelled, state?.code != nil {
                try? await Task.sleep(for: .seconds(1))
                if let checked = library.checkPairing() { state = checked }
            }
        }
    }
}

/// Who's nearby, often, so a new device shows soon after it offers to
/// pair.
struct Nearby: ViewModifier {
    @Environment(Library.self) private var library
    @Binding var devices: [NearbyDevice]

    func body(content: Content) -> some View {
        content.task {
            while !Task.isCancelled {
                devices = await library.nearby()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// A pairing code's six digits, a squircle each, in two groups of three
/// (as codes are read): filled as far as `digits` goes, the rest empty,
/// so the boxes show how long a code is before it's typed. The box the
/// next digit goes in is ringed if `caret`; none, once the code is whole.
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
                if caret, i == digits.count {
                    shape.strokeBorder(Color.accentColor, lineWidth: max(2, size / 12))
                }
            }
    }
}

#if !os(tvOS)
/// The Mac's first run, as its welcome windows are (Xcode's, Keynote's): a
/// small fixed window of the app's icon and name over two large choices;
/// joining shows its code in the same window, as Setup Assistant moves
/// between panes. The iPhone's, for now, is the same, filling its screen.
private struct SetupForm: View {
    @Environment(Library.self) private var library
    /// Whether this device shows a code, to be added to a library.
    @State private var joining = false

    var body: some View {
        Group {
            if joining { joinStep } else { welcome }
        }
        #if os(macOS)
        .frame(width: 520, height: 400)
        // As welcome windows have: no title, the title bar part of the window.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
        #if DEBUG
        // `CINEMATHEQUE_TAB` names a step, as on tvOS: `join`, to show a code.
        .onAppear { if Launch.tab == "join" { joining = true } }
        #endif
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            #else
            Image(systemName: "film.stack")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            #endif
            Text("Welcome to Cinematheque")
                .font(.largeTitle.weight(.semibold))
                .padding(.top, 8)
            Text("The movies and series your household keeps, shared among your devices.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            if let device = library.removedBy {
                Label("This Mac was removed from its library (as \(device) said). Join it again, or create another.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .padding(.top, 12)
            }
            Spacer(minLength: 24)
            VStack(spacing: 10) {
                Button { library.found() } label: {
                    Choice(symbol: "plus.rectangle.on.folder", title: "Create a Library", detail: "Start with your own movies and series.")
                }
                .keyboardShortcut(.defaultAction)
                Button { joining = true } label: {
                    Choice(symbol: "person.2", title: "Join a Library", detail: "Use one that you or your household already has.")
                }
            }
            .buttonStyle(ChoiceStyle())
        }
        .padding(.horizontal, 40)
        .padding(.top, 8)
        .padding(.bottom, 32)
    }

    private var joinStep: some View {
        VStack(spacing: 20) {
            Text("Join a Library").font(.title.weight(.semibold))
            Text("On a device in the library, open Cinematheque's Settings: on a Mac, Devices, and enter this code beside \(Library.thisDevice); on an Apple TV, Your Devices or People, then Add, and choose \(Library.thisDevice).")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            OfferedCode(size: 40)
            Spacer(minLength: 0)
            HStack {
                Button("Back") { joining = false }
                Spacer()
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .onDisappear { library.stopPairing() }
    }
}

/// A welcome window's choice: a symbol, a title, and a line saying what it's for.
private struct Choice: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// A choice's row, as Xcode's welcome window draws its own: quiet until the
/// pointer's over it or it's pressed.
private struct ChoiceStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(configuration.isPressed ? 1 : hovering ? 0.7 : 0.4))
            )
            .onHover { hovering = $0 }
    }
}
#endif
