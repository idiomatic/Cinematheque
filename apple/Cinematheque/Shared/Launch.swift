#if DEBUG
import Foundation

/// Debug builds' launch options, for driving the app unattended (in a VM,
/// by `open --env`; in the tvOS simulator, by `simctl launch` with each
/// prefixed `SIMCTL_CHILD_`).
@MainActor
enum Launch {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// `CINEMATHEQUE_CODE_FILE`: a file to write each pairing code this
    /// device offers to, so a test can send it (`person pair CODE` or
    /// `member pair CODE` from another device).
    static func note(code: String?) {
        guard let path = env["CINEMATHEQUE_CODE_FILE"], let code else { return }
        try? Data((code + "\n").utf8).write(to: URL(filePath: path))
    }

    /// `CINEMATHEQUE_TAB`: a shelf to start on (`movies`, `series`, ...;
    /// tvOS), or in setup, a step (`pair` or `joinOther`), offering its code
    /// (both platforms).
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

    /// `CINEMATHEQUE_LEAVE`, once a launch (tvOS, on Settings): presses
    /// Leave This Library… (`ask`), or presses it and confirms (`confirm`,
    /// the first other member taking over if it asks who).
    static var leave: String? {
        guard !left else { return nil }
        left = true
        return env["CINEMATHEQUE_LEAVE"]
    }
    private static var left = false

    /// `CINEMATHEQUE_ITEM`: the item the URL played is a copy of, for its
    /// progress (macOS).
    static var item: String? { env["CINEMATHEQUE_ITEM"] }
}
#endif
