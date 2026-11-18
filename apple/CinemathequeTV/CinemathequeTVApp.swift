import SwiftUI
import UIKit

@main
struct CinemathequeTVApp: App {
    @State private var library: Library

    init() {
        // Seeds first, which tvOS may have purged with the caches.
        Keys.restore()
        #if DEBUG
        TVLaunch.link()
        #endif
        _library = State(initialValue: Library(home: Keys.home.path))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
        }
    }
}

/// Setting up, until there's a library; then the shelves, refreshing (by
/// syncing, then crawling) once a launch.
struct RootView: View {
    @Environment(Library.self) private var library

    var body: some View {
        Group {
            if library.status == nil {
                ContentUnavailableView("No Home", systemImage: "exclamationmark.triangle", description: Text(library.problem ?? ""))
            } else if !library.hasLibrary {
                TVSetupView()
            } else {
                Shelves()
            }
        }
        .task(id: library.hasLibrary) {
            Keys.save()
            // The Apple TV's name, as set in its settings, until set here.
            await library.startAtLaunch(device: UIDevice.current.name)
        }
    }
}

#if DEBUG
/// Debug builds' launch options, for driving the app unattended (e.g., in
/// the simulator, by `simctl launch` with `SIMCTL_CHILD_` before each):
/// `CINEMATHEQUE_SECRET` and `CINEMATHEQUE_FOUNDER` link this device and
/// join the library before it opens.
enum TVLaunch {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// `CINEMATHEQUE_TAB`: a shelf to start on (`movies`, `series`, ...).
    static var tab: Shelves.Shelf? { env["CINEMATHEQUE_TAB"].flatMap(Shelves.Shelf.init(rawValue:)) }

    /// `CINEMATHEQUE_SELECT`: a title key whose page to open, in the shelf
    /// started on.
    static var select: String? { env["CINEMATHEQUE_SELECT"] }

    /// `CINEMATHEQUE_PLAY`: play the opened title (any value), once a
    /// launch.
    static var play: Bool {
        guard !played, env["CINEMATHEQUE_PLAY"] != nil else { return false }
        played = true
        return true
    }
    private static var played = false

    static func link() {
        let env = ProcessInfo.processInfo.environment
        guard let secret = env["CINEMATHEQUE_SECRET"], let founder = env["CINEMATHEQUE_FOUNDER"] else { return }
        let library = Library(home: Keys.home.path)
        guard !library.hasLibrary else { return }
        library.link(secret)
        library.found(founder)
        Keys.save()
    }
}
#endif
