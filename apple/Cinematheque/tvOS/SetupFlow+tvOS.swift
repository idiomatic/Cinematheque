#if os(tvOS)
import SwiftUI

/// Setting up on an Apple TV, as tvOS apps do: the app's name over a few
/// large choices, each a screen of its own with one thing to enter.
struct SetupFlow: View {
    enum Step: String, Hashable { case link, secret, join, joinOther }

    @Environment(Library.self) private var library
    @State private var path: [Step] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 60) {
                VStack(spacing: 20) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 120))
                        .foregroundStyle(.tint)
                    Text("Cinematheque")
                        .font(.largeTitle.weight(.bold))
                    Text("The movies and shows your household keeps, shared among your devices.")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 24) {
                    NavigationLink(value: Step.link) { Choice("I Use Cinematheque on Another Device") }
                    NavigationLink(value: Step.joinOther) { Choice("Join Someone's Library") }
                    Button { library.found(nil) } label: { Choice("Start a New Library") }
                }
            }
            .frame(maxWidth: 1200)
            #if DEBUG
            // `CINEMATHEQUE_TAB` names a step to open, too.
            .onAppear { if path.isEmpty, let step = Launch.tab.flatMap(Step.init(rawValue:)) { path = [step] } }
            #endif
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .link:
                    PairingStep { path.append(.secret) }
                case .secret:
                    Entry(
                        title: "Enter Your Secret",
                        detail: "On your Mac, open Cinematheque's Settings, then People & Devices › Add a Device.",
                        prompt: "Your secret",
                        secure: true
                    ) { secret in
                        library.link(secret)
                        if library.linked { path.append(.join) }
                    }
                case .join:
                    Entry(
                        title: "Enter the Founder's Key",
                        detail: "It's beside your secret, in Settings › People & Devices › Add a Device.",
                        prompt: "Founder's key"
                    ) { library.found($0) }
                case .joinOther:
                    Entry(
                        title: "Join a Library",
                        detail: "Enter its founder's key. Then someone who shares it adds you, by your key:",
                        prompt: "Founder's key",
                        key: library.status?.user
                    ) { library.found($0) }
                }
            }
        }
    }
}

/// Pairing with another of the user's devices: a code to enter there,
/// which brings this one the user and the library; or, failing that,
/// entering the user's secret instead.
private struct PairingStep: View {
    let enterSecret: () -> Void
    @Environment(Library.self) private var library
    @State private var state: Library.Pairing?
    /// Counts offers, each with a new code.
    @State private var offers = 0

    var body: some View {
        VStack(spacing: 40) {
            Text("Pair with Your Mac").font(.title.weight(.bold))
            Text("On your Mac, open Cinematheque's Settings, then People & Devices › Add a Device, and enter this code beside this Apple TV's name.")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let code = state?.code {
                // In two groups of three, to read at a distance.
                Text(code.prefix(3) + " " + code.suffix(3))
                    .font(.system(size: 140, weight: .semibold, design: .rounded).monospacedDigit())
                    .padding(.horizontal, 60)
                    .padding(.vertical, 20)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
                HStack(spacing: 16) {
                    ProgressView()
                    Text("Waiting for your Mac…").foregroundStyle(.secondary)
                }
            } else if state?.closed == true {
                Text("That was too many wrong codes.").foregroundStyle(.secondary)
                Button("Show a New Code") { offers += 1 }
            }
            Button("Enter Your Secret Instead", action: enterSecret)
            if let problem = library.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 1200)
        .task(id: offers) {
            state = library.offerPairing()
            // Until paired (the app then leaves setup) or stopped.
            while !Task.isCancelled, state?.code != nil {
                try? await Task.sleep(for: .seconds(1))
                if let checked = library.checkPairing() { state = checked }
            }
        }
        .onDisappear { library.stopPairing() }
    }
}

/// One step: what to enter, where to find it, and Continue. tvOS's own
/// keyboard takes it, and an iPhone nearby can type for the remote.
private struct Entry: View {
    let title: String
    let detail: String
    let prompt: String
    var secure = false
    /// A key to show, for someone to add this user by.
    var key: String?
    let done: (String) -> Void
    @Environment(Library.self) private var library
    @State private var text = ""

    var body: some View {
        VStack(spacing: 40) {
            Text(title).font(.title.weight(.bold))
            Text(detail)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let key {
                // In groups of eight, four to a line, to read aloud or copy.
                Text(Self.grouped(key))
                    .font(.title3.monospaced())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            Group {
                if secure { SecureField(prompt, text: $text) } else { TextField(prompt, text: $text) }
            }
            .frame(width: 900)
            Button("Continue") { done(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .disabled(!SetupView.isKey(text))
            if let problem = library.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 1200)
    }

    private static func grouped(_ key: String) -> String {
        let groups = stride(from: 0, to: key.count, by: 8).map { i in
            String(key.dropFirst(i).prefix(8))
        }
        return stride(from: 0, to: groups.count, by: 4).map { groups[$0..<min($0 + 4, groups.count)].joined(separator: " ") }.joined(separator: "\n")
    }
}

/// A setup choice's label, all of one width.
private struct Choice: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).frame(width: 760)
    }
}
#endif
