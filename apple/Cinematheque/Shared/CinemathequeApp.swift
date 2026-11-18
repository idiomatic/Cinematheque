import SwiftUI

@main
struct CinemathequeApp: App {
    @State private var library: Library

    init() {
        let home = Platform.prepareHome()
        #if DEBUG
        Launch.link(home: home)
        #endif
        _library = State(initialValue: Library(home: home))
    }

    var body: some Scene {
        WindowGroup("Cinematheque") {
            RootView()
                .environment(library)
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 560)
                #endif
        }
        #if os(macOS)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Library") { Task { await library.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(!library.hasLibrary || library.activity != nil)
            }
        }
        #endif
        #if os(macOS)
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
        #endif
    }
}

/// Setting up, until there's a library; then browsing it, once it's
/// served and refreshed (by syncing, then crawling) once a launch.
struct RootView: View {
    @Environment(Library.self) private var library

    var body: some View {
        Group {
            if library.status == nil {
                ContentUnavailableView("No Home", systemImage: "exclamationmark.triangle", description: Text(library.problem ?? ""))
            } else if !library.hasLibrary {
                SetupView()
            } else {
                Browser()
            }
        }
        // Again once set up.
        .task(id: library.hasLibrary) {
            Platform.keep()
            await library.startAtLaunch(device: Platform.deviceName, user: Platform.userName)
        }
    }
}
