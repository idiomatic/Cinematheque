import CCinematheque
import SwiftUI

@main
struct CinemathequeApp: App {
    @State private var library: Library

    init() {
        #if os(macOS)
        // Paging by the scroll bar's track jumps rather than animating: the
        // grid's rows coming into view, and their covers, mid-animation had
        // SwiftUI set the scroll position from its own, behind AppKit's,
        // pulling it back as the track was held, and jumping it as it was
        // let go. Stored, as AppKit reads it past registered defaults, and
        // only if unset, so `defaults write` can turn it back on.
        if UserDefaults.standard.object(forKey: "NSScrollAnimationEnabled") == nil {
            UserDefaults.standard.set(false, forKey: "NSScrollAnimationEnabled")
        }
        #if DEBUG
        if let appearance = Launch.appearance { NSApplication.shared.appearance = appearance }
        #endif
        #endif
        let dataDir = Platform.prepareDataDir()
        _library = State(initialValue: Library(dataDir: dataDir))
    }

    var body: some Scene {
        WindowGroup("Cinematheque") {
            RootView()
                .environment(library)
                #if DEBUG && !os(macOS)
                .preferredColorScheme(Launch.colorScheme)
                #endif
        }
        #if os(macOS)
        // Sized by what it shows: the welcome window fixed, the library's
        // from its minimum up.
        .windowResizability(.contentSize)
        .commands {
            // Its version, and in parentheses the build the core was made
            // from, as `/version` serves it.
            CommandGroup(replacing: .appInfo) {
                Button("About Cinematheque") { NSApplication.shared.orderFrontStandardAboutPanel(options: [.version: Self.build]) }
            }
            // Show Inspector and Hide Inspector in the View menu (the
            // system's goes with the inspector, which isn't there hidden).
            CommandGroup(after: .sidebar) { InspectorCommand() }
            CommandGroup(after: .textEditing) { FindCommand() }
            CommandGroup(before: .toolbar) {
                GroupCommand()
                SortCommand()
                Divider()
            }
            CommandGroup(after: .newItem) {
                NewListCommand()
                Divider()
                // With ⌥ held, Refresh Library Fully, listing every folder
                // afresh, as a folder's time doesn't change as a file in
                // it is retagged in place.
                Button("Refresh Library") { Task { await library.refresh() } }
                    .keyboardShortcut("r")
                    .modifierKeyAlternate(.option) {
                        Button("Refresh Library Fully") { Task { await library.refreshFully() } }
                            .keyboardShortcut("r", modifiers: [.command, .option])
                    }
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

    #if os(macOS)
    /// What the core was built from, and how (`cq_version`):
    /// "v0.1-3-ga9eea2d1b2c3, safe".
    private static var build: String {
        struct Version: Decodable { let revision: String; let mode: String }
        guard let text = cq_version() else { return "" }
        defer { cq_free(text) }
        guard let v = try? JSONDecoder().decode(Version.self, from: Data(bytes: text, count: strlen(text))) else { return "" }
        return "\(v.revision), \(v.mode)"
    }
    #endif
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
        .modifier(ListRequests())
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
    /// The library window's least size, on the Mac (setup's is its own):
    /// wide enough, with the sidebar and the inspector shown, for the grid's
    /// toolbar to hold a shelf's action and search beside its name, which
    /// SwiftUI drops, not shrinks, when it's short.
    func browsingSize() -> some View {
        #if os(macOS)
        frame(minWidth: 960, minHeight: 560)
        #else
        self
        #endif
    }
}
