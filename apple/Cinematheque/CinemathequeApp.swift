import SwiftUI

@main
struct CinemathequeApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup("Cinematheque") {
            LibraryView()
                .environment(library)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Library") { Task { await library.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(!library.hasLibrary || library.activity != nil)
            }
        }
        WindowGroup("Player", for: PlayRequest.self) { $request in
            if let request {
                PlayerView(request: request)
                    .environment(library)
            }
        }
        // A player isn't reopened at launch, playing on its own (and, with
        // a debug launch option, beside another).
        .restorationBehavior(.disabled)
        Settings {
            ManageView()
                .environment(library)
        }
    }
}
