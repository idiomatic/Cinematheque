# Apple players

The players for Apple devices, in SwiftUI, on the [core](../core/README.md) through its C interface. So far, a macOS player (macOS 15 or later): it browses a library, plays a copy straight from its repository, and keeps the user's playheads. It opens the library in the peer's home (`CINEMATHEQUE_HOME`, or the default), which the [peer](../peer/README.md) creates and fills (`library create`, `repo add`, `crawl`).

## Building

Open [Cinematheque.xcodeproj](Cinematheque.xcodeproj) in Xcode and run the Cinematheque scheme; Product › Show Build Folder in Finder finds the app in DerivedData. Or, from the command line:

```sh
xcodebuild -scheme Cinematheque -configuration Release build
open "$(xcodebuild -scheme Cinematheque -configuration Release \
  -showBuildSettings | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p')/Cinematheque.app"
```

The project has one macOS app target:
* **Sources:** the [Cinematheque](Cinematheque) folder, which Xcode keeps in sync, so new files need no project edits.
* **Core:** a build phase builds it with Zig (from `/opt/homebrew/bin` or `/usr/local/bin`) for each architecture being built, so Release builds are universal; Swift imports it as `CCinematheque`, by the [module map](../core/include/module.modulemap) beside its header.
* **Bundle:** [Info.plist](Cinematheque/Info.plist), merged into the generated one, allows plain HTTP on the local network, where repositories often are; [Assets.xcassets](Cinematheque/Assets.xcassets) holds the icon and accent color, both empty so far. It's signed ad hoc.
* **Scheme:** shared, with `CINEMATHEQUE_HOME` ready, disabled, for running on another library.

## Sources

* [Library.swift](Cinematheque/Library.swift) opens the library through the C interface and decodes its JSON: titles, and one title's episodes or versions, renditions, and copies with playable URLs, and the user's playheads.
* [LibraryView.swift](Cinematheque/LibraryView.swift): titles by kind (all, movies, series), searchable, beside the one selected. The kind picker and search sit in the sidebar, since under macOS 26's look a sidebar's toolbar holds only its toggle.
* [TitleView.swift](Cinematheque/TitleView.swift): a title's episodes or versions, each with the user's progress or watched mark (and a menu to change it), each rendition by the name its repository gave it, and each copy's location and size, with a button to play or resume it.
* [PlayerView.swift](Cinematheque/PlayerView.swift): a window per copy playing, in AppKit's `AVPlayerView`, streaming from the repository by byte ranges, starting where the user left off and saving the playhead every 10 seconds.
* [Launch.swift](Cinematheque/Launch.swift), in debug builds only: launch options for driving the app unattended, `CINEMATHEQUE_SELECT` (a title key), `CINEMATHEQUE_PLAY` (a URL to open in a player), and `CINEMATHEQUE_ITEM` (its item key, for its playhead).

## Checking the interface

Screenshots come from a macOS VM, run by terrarium from the `macos-27.2-quiet` layer, whose screen it captures without screen-recording permission on the host. Put the debug build's app and a peer home into the guest, at `~/Cinematheque.app` and `~/Library/Application Support/Cinematheque`, then open it with launch options, e.g., `open --env CINEMATHEQUE_SELECT=t/m/all-systems-red/2017 ~/Cinematheque.app`. Drawing the window from within the app instead (`cacheDisplay`, or rendering its layers) misses macOS 26's floating sidebar.

## Findings

* Played from a Caddy server on a NAS, over Wi-Fi: HandBrake's `.m4v` files open in seconds, and seek, with their audio and subtitle tracks.
* SwiftUI's `VideoPlayer` failed to load when the app ran unbundled ("failed to demangle superclass of VideoPlayerView"); AppKit's `AVPlayerView` works either way.
