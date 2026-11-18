#if DEBUG
import Foundation

/// Debug builds' launch options, for driving the app unattended (in a VM,
/// by `open --env`; in the tvOS simulator, by `simctl launch` with each
/// prefixed `SIMCTL_CHILD_`).
@MainActor
enum Launch {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// `CINEMATHEQUE_SECRET` and `CINEMATHEQUE_FOUNDER`: link this device to
    /// the user whose secret it is, and join the founder's library, before
    /// the library opens, if it has none.
    static func link(home: String?) {
        guard let secret = env["CINEMATHEQUE_SECRET"], let founder = env["CINEMATHEQUE_FOUNDER"] else { return }
        let library = Library(home: home)
        guard !library.hasLibrary else { return }
        library.link(secret)
        library.found(founder)
        Platform.keep()
    }

    /// `CINEMATHEQUE_TAB`: a shelf to start on (`movies`, `series`, ...;
    /// tvOS).
    static var tab: String? { env["CINEMATHEQUE_TAB"] }

    /// `CINEMATHEQUE_SELECT`: a tile to select (macOS) or whose title's
    /// page to open (tvOS): a title key, with `#` and a season for a
    /// series' (e.g., `t/s/firefly/-#1`).
    static var selection: String? { env["CINEMATHEQUE_SELECT"] }

    /// The selection's title key.
    static var selectedTitle: String? { selection.map { String($0.split(separator: "#")[0]) } }

    /// `CINEMATHEQUE_PLAY`, once a launch (the views that ask may appear
    /// twice): a URL to play (macOS), or any value to play the opened title
    /// (tvOS).
    static var play: String? {
        guard !played else { return nil }
        played = true
        return env["CINEMATHEQUE_PLAY"]
    }
    private static var played = false

    /// `CINEMATHEQUE_ITEM`: the item the URL played is a copy of, for its
    /// playhead (macOS).
    static var item: String? { env["CINEMATHEQUE_ITEM"] }
}
#endif
