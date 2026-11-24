import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// VLC, if it's installed, for copies Apple's players can't play (MKV,
/// ISO): handed the copy's address (or a download's file) rather than
/// leaving it unplayable. Its progress isn't seen, so none is saved.
enum VLC {
    /// Whether VLC takes a request: its copy is one Apple's players can't
    /// play, and VLC is installed.
    @MainActor static func takes(_ request: PlayRequest) -> Bool {
        !Playback.playsNatively(request.url) && installed
    }

    /// Hands a request to VLC if it takes it; whether it did.
    @MainActor static func handOff(_ request: PlayRequest) -> Bool {
        guard takes(request) else { return false }
        open(request)
        return true
    }

    #if os(macOS)
    private static let bundle = "org.videolan.vlc"

    @MainActor static var installed: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil
    }

    @MainActor private static func open(_ request: PlayRequest) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.open([request.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    #else
    /// VLC's x-callback-url scheme, which both its iPhone and Apple TV apps
    /// take (see DEVELOPMENT.md); asking whether it's there takes its
    /// declaring in Info.plist (`LSApplicationQueriesSchemes`).
    private static let scheme = "vlc-x-callback"

    @MainActor static var installed: Bool {
        URL(string: "\(scheme)://").map(UIApplication.shared.canOpenURL) ?? false
    }

    @MainActor private static func open(_ request: PlayRequest) {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "x-callback-url"
        parts.path = "/stream"
        parts.queryItems = [URLQueryItem(name: "url", value: request.url.absoluteString)]
        #if os(tvOS)
        // Back to the title's page once playback's done, as the Top Shelf
        // opens it.
        if let tile = tileID(of: request.item) {
            var back = URLComponents()
            back.scheme = "cinematheque"
            back.host = "title"
            back.queryItems = [URLQueryItem(name: "tile", value: tile)]
            if let link = back.url { parts.queryItems?.append(URLQueryItem(name: "x-success", value: link.absoluteString)) }
        }
        #endif
        // Every reserved character escaped, as the address is a parameter's
        // value within another URL.
        parts.percentEncodedQuery = parts.queryItems?.map { "\($0.name)=\(($0.value ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&")
        if let url = parts.url { UIApplication.shared.open(url) }
    }

    /// The tile an item's on (its title's, or its season's: `key#season`),
    /// from its full key (`t/s/name/year/e/s01e02…`).
    private static func tileID(of item: String) -> String? {
        let parts = item.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }
        let title = parts[0..<4].joined(separator: "/")
        guard parts.count >= 6, parts[4] == "e", let season = parts[5].dropFirst().prefix(while: \.isNumber).nilIfEmpty, let n = Int(season) else { return title }
        return "\(title)#\(n)"
    }
    #endif
}

private extension Substring {
    var nilIfEmpty: Substring? { isEmpty ? nil : self }
}
