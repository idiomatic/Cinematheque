# Apple players

The players for Apple devices, in SwiftUI, on the [core](../core/README.md) through its C interface. So far, a macOS player (macOS 15 or later): it sets up and manages a library, browses it by cover art, and plays copies straight from their repositories, keeping the user's playheads and watchlist. It opens the peer's home (`CINEMATHEQUE_HOME`, or the default), which it shares with the [peer](../peer/README.md).

## Building

Open [Cinematheque.xcodeproj](Cinematheque.xcodeproj) in Xcode and run the Cinematheque scheme; Product › Show Build Folder in Finder finds the app in DerivedData. Or, from the command line:

```sh
xcodebuild -scheme Cinematheque -configuration Release build
open "$(xcodebuild -scheme Cinematheque -configuration Release \
  -showBuildSettings | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p')/Cinematheque.app"
```

The project is in Xcode 27's format ([project.xcproj](Cinematheque.xcodeproj/project.xcproj), readable JSON, converted with `xcodebuild -convert-project "Xcode Project"`), so it needs Xcode 27 or later. It has one macOS app target:
* **Sources:** the [Cinematheque](Cinematheque) folder, which Xcode keeps in sync, so new files need no project edits.
* **Core:** a build phase builds it with Zig (from `/opt/homebrew/bin` or `/usr/local/bin`) for each architecture being built, so Release builds are universal, and links each into one object exporting only the C interface (`ld -r -exported_symbol '_cq_*'`), since the compiler runtime Zig bundles (which the core needs for 128-bit floats) would otherwise clash with Xcode's. Swift imports it as `CCinematheque`, by the [module map](../core/include/module.modulemap) beside its header.
* **Bundle:** [Info.plist](Cinematheque/Info.plist), merged into the generated one, allows plain HTTP on the local network, where repositories often are; [Assets.xcassets](Cinematheque/Assets.xcassets) holds the icon and accent color, both empty so far. It's signed ad hoc.
* **Scheme:** shared, with `CINEMATHEQUE_HOME` ready, disabled, for running on another library.
* **Settings:** Xcode 27.2's recommended ones (its macOS app template's), but for four, on purpose: script sandboxing is off for the core's build phase, which reads `../core` and Zig's cache; there's no App Sandbox, since the app shares the peer's home in `~/Library/Application Support`; the hardened runtime waits for signing for distribution; and the app runs on macOS 15 or later. Swift code is isolated to the main actor by default, with approachable concurrency; what crosses threads (the core's handle, decoded images) is marked `nonisolated`.
* **Signing:** ad hoc. A developer's own settings, such as `DEVELOPMENT_TEAM`, go in `Local.xcconfig` beside [Signing.xcconfig](Signing.xcconfig), which includes it if present; Git ignores it, so they stay out of commits.

## Sources

* [Library.swift](Cinematheque/Library.swift): the library through the C interface, decoding its JSON (status, tiles, a title's details, repositories, members, the watchlist), and running long operations (crawling, syncing, describing) off the main thread, reloading as they commit. What goes wrong becomes `problem`, a sentence (a long operation's first failure by its server's name, and how many more), with its kind, so only a success of the same kind clears it.
* [SetupView.swift](Cinematheque/SetupView.swift): the first run: creating, joining, or linking.
* [LibraryView.swift](Cinematheque/LibraryView.swift): shelves (Movies, Series, Watchlist) beside a lazy grid of covers in fixed cells, movies 2:3 and seasons square under their series, with watched marks and progress bars; the tiles in view go to the core to be described first while a crawl runs. Each shelf has its own scroll view (one left scrolled past the end of a shorter shelf drew nothing), which returns to the shelf's topmost title, and keeps it at the top when the grid's width changes, as when the inspector opens or closes. Tiles count as visible once half on screen (`onScrollVisibilityChange`), and leave on disappearing too, since a lazy grid drops a tile it scrolls far past without saying so. `StatusBar` floats over the bottom of the grid: counts or what went wrong, and a long operation's progress (`cq_progress`, read twice a second while one runs), fading 3 seconds after it last changed unless something is running or wrong, and returning when the pointer nears it; the grid's bottom margin lets its last row clear it. `ProblemBar` shows what went wrong along the bottom of Settings. Neither is ever an alert. The toolbar holds the inspector's toggle (⌥⌘I) and, last, search: SwiftUI pins its toolbar search to the trailing edge, and the guidelines put both at the trailing edge without ordering them, so the toggle goes just before search, as in Photos (a custom field could put the toggle last, but would lose the native one's behavior).
* [CinemathequeApp.swift](Cinematheque/CinemathequeApp.swift): the windows, Settings, and Refresh Library (⌘R), which syncs, then crawls, as the library window does once at launch.
* [ArtCache.swift](Cinematheque/ArtCache.swift): covers fetched by range request, scaled with ImageIO off the main thread (480 pixels for tiles, 1,200 for the inspector), and kept in memory and on disk (`~/Library/Caches/com.rbrian.cinematheque/covers`); until one loads, its placeholder, rendered by the core from its ThumbHash and scaled up, or without one, a color of its own with its title. A cover replaces its placeholder at once (a fade, tried at 3, 0.3, and 0.1 seconds, wasn't worth it); one in memory shows from the start, so scrolling back shows no placeholder.
* [InspectorView.swift](Cinematheque/InspectorView.swift): the selected tile's larger cover, Play or Resume (a season from its next unwatched episode, the rest queued), a rendition picker, the watchlist and watched marks, metadata, a movie's versions, and a season's episodes (season 0 as Specials), described on demand.
* [PlayerView.swift](Cinematheque/PlayerView.swift): a window per queue, an `AVQueuePlayer` holding the whole queue in AppKit's `AVPlayerView`, streaming by byte ranges, starting where the user left off, saving the playhead every 10 seconds (but not within the first 10, where a resume's seek may not have landed) and where it's paused or its window closed (so stopping within the first 10 seconds deletes it), reloading the grid's progress when it stops, and at each item's end, marking it watched and playing the next.
* [ManageView.swift](Cinematheque/ManageView.swift): Settings: repositories, members, and this device.
* [Launch.swift](Cinematheque/Launch.swift), in debug builds only: launch options for driving the app unattended, `CINEMATHEQUE_SELECT` (a tile: a title key, with `#` and a season for a series', e.g., `t/s/firefly/-#1`), `CINEMATHEQUE_PLAY` (a URL to open in a player), and `CINEMATHEQUE_ITEM` (its item key, for its playhead).

## Checking the interface

Screenshots come from a macOS VM, run by terrarium from the `macos-27.2-quiet` layer, whose screen it captures without screen-recording permission on the host. Put the debug build's app into the guest, at `~/Cinematheque.app`, with media and the [peer](../peer/README.md) to serve it on the guest's loopback (`serve --media`), then open the app, to set up from scratch, or with a peer home in place and launch options, e.g., `open --env CINEMATHEQUE_SELECT=t/m/all-systems-red/2017 ~/Cinematheque.app`. During a tight loop of changes, keep the VM running and only replace the app (quit it, copy the new build in, reopen it), keeping the guest's media server and home; stop the VM when the work moves away from the interface. Drawing the window from within the app instead (`cacheDisplay`, or rendering its layers) misses macOS 26's floating sidebar.

## Findings

* Played from a Caddy server on a NAS, over Wi-Fi: HandBrake's `.m4v` files open in seconds, and seek, with their audio and subtitle tracks.
* Of 14 HandBrake files on a NAS, every one carried a JPEG cover (2:3 posters for movies, 667×1000; squares for TV, 800×800) and a description.
* A tile with both a double-click and a single-click gesture delays selection by the double-click interval; selecting is a plain tap, and playing a simultaneous double tap.
* SwiftUI's `VideoPlayer` failed to load when the app ran unbundled ("failed to demangle superclass of VideoPlayerView"); AppKit's `AVPlayerView` works either way.
