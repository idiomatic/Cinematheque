#if DEBUG
import Foundation

/// Debug builds' launch options, for driving the app unattended (e.g., in a
/// VM, with `open --env`): a title to select, and a copy to play.
@MainActor
enum Launch {
    /// A title to select first, from `CINEMATHEQUE_SELECT`.
    static var selection: String? { ProcessInfo.processInfo.environment["CINEMATHEQUE_SELECT"] }

    /// The item that URL is a copy of, from `CINEMATHEQUE_ITEM`.
    static var item: String? { ProcessInfo.processInfo.environment["CINEMATHEQUE_ITEM"] }

    /// A URL to play first, from `CINEMATHEQUE_PLAY`.
    static var play: URL? { ProcessInfo.processInfo.environment["CINEMATHEQUE_PLAY"].flatMap(URL.init(string:)) }
}
#endif
