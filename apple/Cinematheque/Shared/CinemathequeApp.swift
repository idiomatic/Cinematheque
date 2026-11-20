import SwiftUI

@main
struct CinemathequeApp: App {
    @State private var library: Library

    init() {
        let dataDir = Platform.prepareDataDir()
        _library = State(initialValue: Library(dataDir: dataDir))
    }

    var body: some Scene {
        WindowGroup("Cinematheque") {
            RootView()
                .environment(library)
        }
        #if os(macOS)
        // Sized by what it shows: the welcome window fixed, the library's
        // from its minimum up.
        .windowResizability(.contentSize)
        .commands {
            // Show Inspector and Hide Inspector in the View menu.
            InspectorCommands()
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
                ContentUnavailableView("Can't Open the Library", systemImage: "exclamationmark.triangle", description: Text(library.problem ?? ""))
                    .browsingSize()
            } else if !library.hasLibrary {
                SetupView()
            } else {
                Browser()
                    .browsingSize()
            }
        }
        // Again once set up.
        .task(id: library.hasLibrary) {
            Platform.keep()
            await library.startAtLaunch(device: Platform.deviceName, person: Platform.personName)
            await library.keepInSync()
        }
        .background { PhaseWatcher() }
    }
}

/// The scene's phase, watched beside the views rather than by their root,
/// whose every phase change would otherwise redraw them all (the tab bar's
/// glass, too) while the system snapshots the app going to the background.
private struct PhaseWatcher: View {
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Color.clear
            // Back at the front (as an Apple TV app returns from the home
            // screen, never relaunched), what other devices changed meanwhile.
            .onChange(of: phase) {
                #if os(tvOS)
                // The Mac keeps syncing behind other apps; an Apple TV app in
                // the background is about to be suspended.
                library.active = phase == .active
                #endif
                if phase == .active { Task { await library.syncQuietly() } }
            }
    }
}

extension View {
    /// The library window's least size, on the Mac (setup's is its own).
    func browsingSize() -> some View {
        #if os(macOS)
        frame(minWidth: 900, minHeight: 560)
        #else
        self
        #endif
    }
}
