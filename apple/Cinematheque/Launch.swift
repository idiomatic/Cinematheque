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

    /// A URL to play first, from `CINEMATHEQUE_PLAY`.
    static var play: URL? { ProcessInfo.processInfo.environment["CINEMATHEQUE_PLAY"].flatMap(URL.init(string:)) }
}
#endif
