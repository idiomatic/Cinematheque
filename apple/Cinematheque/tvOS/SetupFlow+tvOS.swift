#if os(tvOS)
import SwiftUI

/// Setting up on an Apple TV, as tvOS apps do: the app's name over a few
/// large choices, each a screen of its own with one thing to enter.
struct SetupFlow: View {
    enum Step: String, Hashable { case link, joinOther }

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
                    PairingStep(
                        join: false,
                        title: "Pair with Your Mac",
                        detail: "On your Mac, open Cinematheque's Settings, then People & Devices, and under New Devices, enter this code beside this Apple TV's name."
                    )
                case .joinOther:
                    PairingStep(
                        join: true,
                        title: "Join a Library",
                        detail: "On their Mac, someone who shares the library opens Cinematheque's Settings, then People & Devices, and under New Devices, enters this code beside this Apple TV's name."
                    )
                }
            }
        }
    }
}

/// Pairing with a member's device, by a code to enter there: to be another
/// of that user's devices, or (`join`) a new member's.
private struct PairingStep: View {
    let join: Bool
    let title: String
    let detail: String
    @Environment(Library.self) private var library

    var body: some View {
        VStack(spacing: 40) {
            Text(title).font(.title.weight(.bold))
            Text(detail)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            OfferedCode(join: join)
            if let problem = library.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 1200)
        .onDisappear { library.stopPairing() }
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
