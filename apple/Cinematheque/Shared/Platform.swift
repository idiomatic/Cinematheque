import Foundation
#if os(macOS)
import AppKit
import IOKit
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
        #if DEBUG && !os(macOS)
        // `CINEMATHEQUE_DATA`, as the Mac and the command-line app honor it
        // (there, the core reads it): a simulator's app run on a library of
        // the Mac's, such as the mock one, its own left alone.
        if let given = Launch.dataDir { return given }
        #endif
        #if os(tvOS)
        Keys.restore()
        return Keys.dataDir.path
        #elseif os(iOS)
        // The app's own Application Support, which iOS keeps and backs up.
        let dir = URL.applicationSupportDirectory.appending(path: "Cinematheque")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
        #else
        return nil
        #endif
    }

    /// Keeps what the data directory has gained that a purge would lose (on tvOS,
    /// seeds, in the Keychain).
    static func keep() {
        #if os(tvOS)
        guard !givenDataDir else { return }
        Keys.save()
        #endif
    }

    /// Forgets what `keep` kept, as a device removed from its library does,
    /// and what the Top Shelf shows of it.
    static func forget() {
        #if os(tvOS)
        guard !givenDataDir else { return }
        Keys.clear()
        TopShelfPublisher.clear()
        #endif
    }

    /// Whether the data directory is one given at launch, whose seeds the
    /// Keychain, which holds this device's own, mustn't take or lose.
    private static var givenDataDir: Bool {
        #if DEBUG
        Launch.dataDir != nil
        #else
        false
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

    /// What kind of device this is, for the member's device to show under
    /// its name as it offers to be added: a Mac's own name for its model
    /// ("MacBook Pro (14-inch, 2021)"), else its identifier (`iPhone14,4`),
    /// which the core names.
    static var model: String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #endif
        #if os(macOS)
        // Apple silicon's, in its device tree; an Intel Mac's identifier.
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        if product != 0 {
            defer { IOObjectRelease(product) }
            if let name = IORegistryEntryCreateCFProperty(product, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
                let text = String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)
                if !text.isEmpty { return text }
            }
        }
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var model = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else { return "" }
        return String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
        #else
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
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
    /// none on an Apple TV or an iPhone, which have no account's name to
    /// offer.
    static var personName: String? {
        #if os(macOS)
        NSFullUserName().split(separator: " ").first.map(String.init)
        #else
        nil
        #endif
    }
}
