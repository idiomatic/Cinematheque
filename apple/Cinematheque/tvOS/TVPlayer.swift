#if os(tvOS)
import AVKit
import SwiftUI
import UIKit

extension PlayRequest: Identifiable {
    var id: Self { self }
}

/// Plays a queue full screen in the system's player, its info panel showing
/// each item's title and description; leaving it (Menu, or Back) stops it
/// where it is.
struct TVPlayer: UIViewControllerRepresentable {
    let request: PlayRequest
    @Environment(Library.self) private var library

    @MainActor
    final class Coordinator {
        var session: PlaybackSession?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let descriptions = Self.descriptions(request, library)
        let session = PlaybackSession(request: request, library: library) { playerItem, entry in
            playerItem.externalMetadata = Self.metadata(title: entry.title, description: descriptions[entry.item])
        }
        controller.player = session.player
        session.play()
        context.coordinator.session = session
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.session?.close()
    }

    /// Each queued item's description (an episode's, else its title's).
    private static func descriptions(_ request: PlayRequest, _ library: Library) -> [String: String] {
        let first = PlayRequest.Entry(url: request.url, item: request.item, title: request.title)
        var out: [String: String] = [:]
        var details: [String: TitleDetail] = [:]
        for entry in [first] + request.queue {
            // An item key is its title's key, then `/v/` or `/e/`.
            guard let cut = entry.item.range(of: "/v/") ?? entry.item.range(of: "/e/") else { continue }
            let titleKey = String(entry.item[..<cut.lowerBound])
            let itemKey = String(entry.item[entry.item.index(after: cut.lowerBound)...])
            if details[titleKey] == nil { details[titleKey] = library.detail(titleKey) }
            let detail = details[titleKey]
            out[entry.item] = detail?.items.first { $0.key == itemKey }?.fields["description"] ?? detail?.fields["description"]
        }
        return out
    }

    private static func metadata(title: String, description: String?) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item.copy() as! AVMetadataItem
        }
        return [item(.commonIdentifierTitle, title)] + (description.map { [item(.commonIdentifierDescription, $0)] } ?? [])
    }
}

/// Which rendition an Apple TV plays: one in a format it plays (MP4, not
/// MKV or ISO), at the most its display shows (2160p on a 4K display, else
/// up to 1080p).
enum TVRendition {
    static func best(_ item: TitleDetail.Item?) -> String? {
        guard let item else { return nil }
        let playable = item.renditions.filter { r in r.copies.contains { playable($0.url) } }
        let limit = UIScreen.main.nativeBounds.height >= 2160 ? 2160 : 1080
        return playable.max { a, b in score(a.label, limit) < score(b.label, limit) }?.label
    }

    private static func playable(_ url: String) -> Bool {
        let ext = (URL(string: url)?.pathExtension ?? "").lowercased()
        return ["mp4", "m4v", "mov"].contains(ext)
    }

    /// The highest resolution up to the limit, then those above it, least
    /// first; a label without one ranks low.
    private static func score(_ label: String, _ limit: Int) -> Int {
        guard let match = label.firstMatch(of: /(\d{3,4})p/), let height = Int(match.1) else { return 0 }
        return height <= limit ? 10_000 + height : 10_000 - height
    }
}
#endif
