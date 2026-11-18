#if os(macOS)
#if DEBUG
import Foundation

/// Debug builds' launch options, for driving the app unattended (e.g., in a
/// VM, with `open --env`): a tile to select, and a copy to play.
@MainActor
enum Launch {
    /// A tile to select first, from `CINEMATHEQUE_SELECT`: a title key, with
    /// `#` and a season for a series' (e.g., `t/s/firefly/-#1`).
    static var selection: String? { ProcessInfo.processInfo.environment["CINEMATHEQUE_SELECT"] }

    /// The item that URL is a copy of, from `CINEMATHEQUE_ITEM`.
    static var item: String? { ProcessInfo.processInfo.environment["CINEMATHEQUE_ITEM"] }

    /// A URL to play first, from `CINEMATHEQUE_PLAY`, once a launch: the
    /// library view can appear twice before its player window opens.
    static var play: URL? {
        guard !played else { return nil }
        played = true
        return ProcessInfo.processInfo.environment["CINEMATHEQUE_PLAY"].flatMap(URL.init(string:))
    }
    private static var played = false
}
#endif
#endif
