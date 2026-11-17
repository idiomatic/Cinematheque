import SwiftUI

@main
struct CinemathequeApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup("Cinematheque") {
            LibraryView()
                .environment(library)
        }
        WindowGroup("Player", for: PlayRequest.self) { $request in
            if let request {
                PlayerView(request: request)
                    .environment(library)
            }
        }
    }
}
