#if DEBUG
#if os(macOS)
import AppKit
#endif
import SwiftUI

/// Debug builds' launch options, for driving the app unattended (in a VM,
/// by `open --env`; in the tvOS simulator, by `simctl launch` with each
/// prefixed `SIMCTL_CHILD_`).
@MainActor
enum Launch {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// `CINEMATHEQUE_DATA` on iOS and tvOS: a data directory to run on (in
    /// a simulator, one of the Mac's), not the app's own.
    static var dataDir: String? { env["CINEMATHEQUE_DATA"] }

    /// `CINEMATHEQUE_TAB`: a section's page to open (`movies`, `series`,
    /// `lists`, `watched`, `search`, or `settings`; tvOS), or in setup, a
    /// step (`join`), offering its code (both platforms).
    static var tab: String? { env["CINEMATHEQUE_TAB"] }

    /// `CINEMATHEQUE_SELECT`: a tile to select (macOS) or whose title's
    /// page to open (tvOS): a title key, with `#` and a season for a
    /// series' (e.g., `t/s/firefly/-#1`).
    static var selection: String? { env["CINEMATHEQUE_SELECT"] }

    /// Takes the selection, once a launch (iOS, where each tab's stack
    /// asks): whether it's this asker's to open.
    static func takeSelection() -> Bool {
        guard !selectionTaken else { return false }
        selectionTaken = true
        return true
    }
    private static var selectionTaken = false

    /// The selection's title key.
    static var selectedTitle: String? { selection.map { String($0.split(separator: "#")[0]) } }

    /// `CINEMATHEQUE_APPEARANCE`: `dark` or `light`, the app's whatever
    /// the system's, for screenshots in each (the tvOS simulator's can't
    /// be set from outside).
    static var colorScheme: ColorScheme? {
        switch env["CINEMATHEQUE_APPEARANCE"] {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    #if os(macOS)
    /// The app's appearance, as `colorScheme` names it, for AppKit's menus
    /// and windows alike.
    static var appearance: NSAppearance? {
        colorScheme.flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
    }
    #endif
}
#endif
