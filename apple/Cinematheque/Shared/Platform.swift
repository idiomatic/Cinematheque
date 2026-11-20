import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What differs by platform outside the interface: where this device's data
/// directory is, and the names a device and its person start with.
enum Platform {
    /// Readies the data directory, returning it, or nil for the core's default (on
    /// macOS, the one the command-line app shares). On tvOS, which may
    /// purge the caches that hold it, first puts back its seeds from the
    /// Keychain.
    static func prepareDataDir() -> String? {
        #if os(tvOS)
        Keys.restore()
        return Keys.dataDir.path
        #else
        return nil
        #endif
    }

    /// Keeps what the data directory has gained that a purge would lose (on tvOS,
    /// seeds, in the Keychain).
    static func keep() {
        #if os(tvOS)
        Keys.save()
        #endif
    }

    /// Forgets what `keep` kept, as a device removed from its library does,
    /// and what the Top Shelf shows of it.
    static func forget() {
        #if os(tvOS)
        Keys.clear()
        TopShelfPublisher.clear()
        #endif
    }

    /// How long each of playback's fades takes, in seconds: its picture to
    /// black and back, and its sound to silence and back.
    static let fade = 0.5

    /// How much resuming replays, in seconds: its fade from black starts
    /// this much before where playing was left, as its fade to black ended.
    static let replay = 4.0

    /// This device's name until one's set: the computer's, or the Apple
    /// TV's as set in its settings.
    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    /// The tallest display's height in pixels, for the quality to play.
    @MainActor static var displayHeight: CGFloat {
        #if os(macOS)
        NSScreen.screens.map { $0.frame.height * $0.backingScaleFactor }.max() ?? 1080
        #else
        UIScreen.main.nativeBounds.height
        #endif
    }

    /// The person's name until one's set: the account's first name on a Mac;
    /// none on an Apple TV, which has no account's name to offer.
    static var personName: String? {
        #if os(macOS)
        NSFullUserName().split(separator: " ").first.map(String.init)
        #else
        nil
        #endif
    }
}
