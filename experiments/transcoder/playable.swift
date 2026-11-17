// Reports whether AVFoundation can play each file or URL, and its tracks.
// Usage: swift playable.swift <path or URL>...
import AVFoundation

for argument in CommandLine.arguments.dropFirst() {
    let url = argument.contains("://") ? URL(string: argument)! : URL(fileURLWithPath: argument)
    let asset = AVURLAsset(url: url)
    do {
        let (playable, duration) = try await asset.load(.isPlayable, .duration)
        let tracks = try await asset.load(.tracks)
        var kinds: [String] = []
        for track in tracks {
            let playable = try await track.load(.isPlayable)
            kinds.append("\(track.mediaType.rawValue)\(playable ? "" : " (unplayable)")")
        }
        print("\(url.lastPathComponent): playable \(playable), \(Int(duration.seconds)) s, \(kinds.joined(separator: ", "))")
    } catch {
        print("\(url.lastPathComponent): \(error.localizedDescription)")
    }
}
