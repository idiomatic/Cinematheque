import CCinematheque
import Foundation
import Observation

/// A title, as the core lists it.
struct Title: Codable, Identifiable, Hashable {
    let key: String
    let name: String
    let year: Int?
    let kind: String
    let items: Int
    let renditions: Int
    let labels: [String]
    let alias: String?

    var id: String { key }
    var isSeries: Bool { kind == "series" }
}

/// One title in full, with where each copy is.
struct TitleDetail: Codable {
    struct Copy: Codable, Hashable {
        let url: String
        let size: Int
        let mtime: String
        let repository: String
    }

    struct Rendition: Codable, Hashable {
        let label: String
        let name: String
        let copies: [Copy]
    }

    struct Item: Codable, Hashable, Identifiable {
        let key: String
        let renditions: [Rendition]
        /// This user's playhead, in milliseconds.
        let position: Int
        let duration: Int
        let watched: Bool
        var id: String { key }
    }

    let key: String
    let name: String
    let year: Int?
    let aliasOf: String?
    let aliases: [String]
    let items: [Item]
}

/// The library, through the core's C interface.
@MainActor @Observable
final class Library {
    private var handle: OpaquePointer?
    private(set) var titles: [Title] = []
    private(set) var error: String?
    /// Counts changes to playheads, so views showing them can refresh.
    private(set) var revision = 0

    /// Opens the library in the peer's home: `CINEMATHEQUE_HOME`, or the
    /// default.
    init() {
        handle = cq_open(nil)
        guard handle != nil else {
            error = "Couldn't open the library (\(String(cString: cq_error()))). Create one with the cinematheque command (library create, repo add, crawl)."
            return
        }
        reload()
    }

    func reload() {
        guard let handle, let json = call({ cq_titles(handle) }) else { return }
        do {
            titles = try JSONDecoder().decode([Title].self, from: json)
                .filter { $0.alias == nil && $0.renditions > 0 }
                .sorted { ($0.name.localizedStandardCompare($1.name), $0.year ?? 0) < (.orderedSame, $1.year ?? 0) }
        } catch {
            self.error = "Couldn't read the library: \(error)"
        }
    }

    func detail(_ key: String) -> TitleDetail? {
        guard let handle, let json = call({ cq_title(handle, key) }) else { return nil }
        return try? JSONDecoder().decode(TitleDetail.self, from: json)
    }

    /// Records this user's playhead in an item (a title's key and an
    /// item's, e.g., "t/m/alien/1979/v/-").
    func setPlayhead(_ item: String, position: Double, duration: Double) {
        guard let handle, position.isFinite, duration.isFinite, duration > 0 else { return }
        if cq_set_playhead(handle, item, UInt64(max(0, position) * 1000), UInt64(duration * 1000)) != 0 {
            error = String(cString: cq_error())
        }
        revision += 1
    }

    func setWatched(_ item: String, _ watched: Bool) {
        guard let handle else { return }
        if cq_set_watched(handle, item, watched ? 1 : 0) != 0 {
            error = String(cString: cq_error())
        }
        revision += 1
    }

    private func call(_ body: () -> UnsafeMutablePointer<CChar>?) -> Data? {
        guard let text = body() else {
            error = String(cString: cq_error())
            return nil
        }
        defer { cq_free(text) }
        return Data(bytes: text, count: strlen(text))
    }

    isolated deinit {
        cq_close(handle)
    }
}

extension ComparisonResult: @retroactive Comparable {
    public static func < (a: ComparisonResult, b: ComparisonResult) -> Bool { a.rawValue < b.rawValue }
}
