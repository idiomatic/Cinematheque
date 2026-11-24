# Using Cinematheque

How to install Cinematheque, give it your videos, and share it with your household. The [README](../README.md) says what it is; [cli/README.md](../cli/README.md) covers the command line in full.

* [Installing](#installing)
* [Getting started](#getting-started)
* [Sources](#sources): [a folder](#a-folder), [a web server](#a-web-server), [naming](#naming), [quality](#quality), [refreshing](#refreshing)
* [Watching](#watching)
* [Downloading](#downloading)
* [Sharing a library](#sharing-a-library)
* [In a browser](#in-a-browser)

## Installing

* **The Mac app** and **the command-line app** (for macOS and Linux) are on the [releases page](https://github.com/idiomatic/Cinematheque/releases), with what changed in each ([CHANGELOG.md](../CHANGELOG.md)).
* **The Apple TV and iPhone apps** aren't released yet; build them with Xcode, as [apple/README.md](../apple/README.md) says.
* **Without a screen,** on a home server or a NAS that runs Linux, the command-line app builds and shares a library, and offers it to browsers (see [In a browser](#in-a-browser)).

Check a download against its `.sha256` file:

* macOS: `shasum -a 256 -c FILE.sha256`
* Linux: `sha256sum -c FILE.sha256`

### The Mac app

Releases aren't notarized yet, so macOS stops the app the first time:

1. Unzip it, move Cinematheque.app to Applications, and open it.
2. When macOS says it can't check it for malicious software, choose Done.
3. In System Settings › Privacy & Security, under Security, choose Open Anyway beside Cinematheque, and confirm with your password.

Control-click › Open no longer gets past the check since macOS 15. Or clear the download's mark in Terminal, then open it as usual:

```sh
xattr -dr com.apple.quarantine /Applications/Cinematheque.app
```

### The command-line app

* **On macOS,** clear the mark a browser's download leaves (a file fetched with `curl` has none), then run it:

  ```sh
  tar -xzf cinematheque-*.tar.gz
  xattr -d com.apple.quarantine cinematheque
  ./cinematheque --version
  ```

* **On Linux,** it needs SQLite and Avahi's library for DNS-SD, with Avahi's daemon running:
  * Alpine: `apk add sqlite-libs avahi-compat-libdns_sd`
  * Fedora: `dnf install sqlite-libs avahi-compat-libdns_sd`
  * Debian, Ubuntu: `apt install libsqlite3-0 libavahi-compat-libdnssd1`

### Your local network

When either app first reaches your network, macOS asks to let it find devices on your local network. Allow it, or it can't reach your NAS or your other devices (System Settings › Privacy & Security › Local Network changes it later). The command-line app asks through Terminal, so start it from there.

## Getting started

1. On first run, an app creates a library, or joins one by a code it shows (see [Sharing a library](#sharing-a-library)).
2. Add a source, a folder or server of your videos (see [Sources](#sources)). The library fills in as it looks through it.

The Mac's Settings manage sources, people, and devices, so a household needs no command line. On a Mac, the app and the command-line app share one library, so either can manage it.

## Sources

A source is a folder of videos your devices can reach over your network. The easiest is one you already have, as it is: Cinematheque only reads it, and never changes its files.

### A folder

* **On a Mac,** choose Add Folder… in Settings › Sources: a folder on the Mac, on a drive plugged into it, or on a NAS share mounted in Finder. While the app runs, it shares the folder with your other devices, which play from it.
* **Anywhere else,** on macOS or Linux, the command-line app shares a folder, then adds it:

  ```sh
  cinematheque serve --media /srv/videos
  cinematheque source add http://hal.local:8008/media/
  ```

### A web server

If your videos are on a server that already serves files, such as a NAS's web server, Caddy, nginx, or Apache, add its address instead: Add Server… on the Mac, or `cinematheque source add URL`.

* **Seeking:** any server that lists its folders will do if players can seek within a file, as nearly all can. Python's built-in `http.server` can't: its videos are listed, but won't play.
* **No listings?** Put a file named `INDEX` in the served folder, listing its files, and remake it whenever they change:

  ```sh
  find . -type f ! -name INDEX > INDEX
  ```

  It works on Linux, macOS, BSD, and most NAS shells. An `INDEX` is also the fastest way to read a large source; the command-line app's server makes one for you.

### Naming

Cinematheque understands the naming conventions of Plex, Jellyfin, and Kodi, and common download names. Titles are recognized best with the year, and series by their folders:

```
Movies/All Systems Red (2017).mkv
Movies/All Systems Red (2017) - Director's Cut.mkv
Movies/Network Effect (2020) {tmdb-12345}/Network Effect (2020).mkv
TV Shows/Worldhoppers/Worldhoppers 102 The Wormhole.m4v
TV Shows/Sanctuary Moon (2019)/Season 01/Sanctuary Moon - S01E01 - Pilot.mkv
TV Shows/Worldhoppers/Worldhoppers The Lost Signal.m4v
```

* **Specials:** a file without an episode number beside a series' episodes, named for the series (`Worldhoppers The Lost Signal`), or in a `Specials` folder, is one of the series' specials.
* **Dated videos,** as a channel's archive has them, are a series of a season a year and an episode a day:

  ```
  Channels/Feed Watch/Feed Watch 2024-03-12 The Wormhole Explained [youtube-ID].mp4
  ```

  The ID tag keeps two videos of one day apart. The words between the date and the tag are the video's title, for browsing the folder, and aren't read for a year or an episode code. yt-dlp writes such names with this output template:

  ```
  %(channel)s/%(channel)s %(upload_date>%Y-%m-%d)s %(title).150B [youtube-%(id)s].%(ext)s
  ```

* **Inconsistent names** (a year off by one, a title spelled two ways, a file copied twice): the command-line app's review lists what looks related, and an alias, recorded once, tells every device that two entries are the same title; see [cli/README.md](../cli/README.md#titles).

### Quality

A file's quality comes from its name (its resolution, origin, codec, and dynamic range), so a title's qualities can sit side by side, and the apps' Quality picker chooses which to play:

```
Movies/All Systems Red (2017)/All Systems Red (2017) - 1080p.mkv
Movies/All Systems Red (2017)/All Systems Red (2017) - 4K HDR.mkv
Movies/Network.Effect.2020.1080p.BluRay.x264-GROUP.mkv
```

A name that says nothing takes its folder's, or that folder's folder's, up to the source. Where a source's files are all one quality though nothing says so (everything one encoder preset made, say), say it for the whole source, or have each first folder within it name its quality:

* **On the Mac:** in a source's sheet in Settings › Sources, Quality: From the Folder Under It, or Named.
* **On the iPhone:** on a source's page in Settings › Sources.
* **On the command line:** `source add URL --quality NAME`, or `--quality-by folder`.

### Refreshing

* **Refresh Library** (⌘R on the Mac) catches up with your other devices first, as they do on their own anyway, then looks through your sources: it reads each one's listings, recognizes titles from file and folder names, and records each file as a copy of its title, in its quality.
* **Later looks** reread only the folders that changed; Refresh Library Fully (⌥⌘R) rereads them all, as retagging a file doesn't change its folder.
* **On their own,** devices look about once a day, sparing a NAS's disks; Look for videos in the Mac's Settings › Sources (Look for New Videos in the Apple TV's and iPhone's Settings) changes how often, for everyone.
* **Renamed or moved files** keep their place in the library, as long as the name still says the same title.
* **Unplugged drives:** when a folder's drive is unplugged or its share unmounted, its videos stay in the library, dimmed, until it's back, a year passes, or you remove them in Settings › Sources.
* **Removing a source** removes its videos from the library on every device, so titles it alone held stop showing; its files stay where they are.

## Watching

* **Browsing:** by cover art: movies, and each series by season. A series' tile shows the season you'd watch next.
* **Playing** resumes where you left off, on any of your devices. A season plays on from the episode you're partway through, else its next unwatched one.
* **Starting over:** Start Over, or stopping within the first 10 seconds, which forgets where you were, so going back to the start sticks.
* **Covers and descriptions** come from your sources:
  * a `poster.jpg` beside a movie, or a `season01-poster.jpg` beside a series, if you keep them;
  * else the cover and details your MP4 files carry, as HandBrake, iTunes, and tagging tools write them.
* **Before a cover loads,** its tile shows a blurred likeness of it, which travels with the library, so even a newly paired device shows one at once.
* **Lists** (a Watchlist, Favorites), like what you've watched, are yours alone, unless you share one with everyone in the library. A title not in the library yet can go on one too, by name, and takes its place when it comes.
* **What plays:** Apple's players and browsers play MP4, M4V, and MOV files, not MKV or ISO. With [VLC](https://www.videolan.org/vlc/) installed, the Mac, iPhone, and Apple TV hand an MKV or ISO to it instead (Play says "Play in VLC"); where you stop there isn't saved.

## Downloading

On a Mac, download what you'll watch away from home, or keep on hand when the network is slow:

* **Movies:** the Download button says its size.
* **Series:** a season's Download menu chooses which episodes the Mac keeps as you watch: the Next one or few, or All.
* **Where:** `~/Movies/Cinematheque`, unless Settings › Downloads says otherwise.
* **Space:** each choice gives its size and the space available for downloads: what's free, less the 20 GB Cinematheque always leaves free. It warns when a choice wouldn't fit.
* **While something streams,** downloads wait, so as not to slow it.
* **Sharing:** your downloads are a source like any other, so your other devices play from them while the app runs.
* **What stays:** what you download yourself stays until you delete it, with the trash button beside the Download controls, which asks first if it's the only copy.
* **What goes:** a series' episodes you've watched are deleted when their space is needed (unless you chose All), but only if a source still holds the same file, never the only copy.

## Sharing a library

1. On the new device, choose Join a Library. It shows a 6-digit code.
2. On a device already in the library, find the new device among those offering nearby, enter its code, and choose whose device it is: yours, to use the library as yourself, with your progress and lists, or someone new's, who joins as a member.
   * **A Mac:** in Settings › Devices › New Devices, then Yours or Someone New.
   * **An Apple TV or iPhone:** at the end of Settings › Your Devices (yours) or Settings › People (someone new's).
   * **The command-line app:** `cinematheque person pair CODE`, or `cinematheque member pair CODE`; off your network too (see [cli/README.md](../cli/README.md#sharing-a-library)).

Devices find each other on your network, and sync on their own while the apps run: a minute after they last did, whenever one comes to the front, and a second after you make a change.

* **The code** seals what's sent, so only the device showing it can open it. The new device stops answering an address after 3 wrong tries from it, and everyone after 30, until it offers a new code.
* **The founder,** whoever created the library, can hand it over to another member.
* **Removing** a member or a device stops their later changes everywhere, while what they did before stands. Any member can remove another, but not the founder.
* **Trust:** each device checks, by signature, that every change comes from a member, so a device that relays the library can't alter it. Each serves the library only to members' devices.

## In a browser

The command-line app serves a web client, so you set up, browse, and play the library in a browser, with nothing installed. It runs on a computer that stays on: a home server, a NAS that runs Linux, or a Mac.

1. **Get the command-line app** onto that computer (see [Installing](#installing)).
2. **Serve it,** with a folder of videos (`--media`), and if you like, a folder to keep downloads in for your other devices (`--downloads`):

   ```sh
   cinematheque serve --media /srv/videos --downloads /srv/kept
   ```

3. **Open it in a browser on that computer:** `http://localhost:8008/`. From another computer, reach it through an SSH tunnel, which counts as that computer's own: `ssh -L 8008:localhost:8008 hal`, then open `http://localhost:8008/` there.
4. **Give it a library,** one of two ways:
   * **Create a Library,** if you have none yet.
   * **Join a Library,** to add it to one you have: it shows a code. Add it from one of your devices already in the library, as yours (see [Sharing a library](#sharing-a-library)); the browser acts as that device's person, so add it from a device of whoever watches there.
5. **Add its folder as a source:** in Settings › Sources, choose Add This Server's Folder, then Refresh Library.
6. **Keep it running** in the background, as [cli/README.md](../cli/README.md#in-the-background) says, so it's there whenever someone opens it.

What to know:

* **Only a browser on that computer** acts as it (or one through an SSH tunnel to it), as anyone who could reach the port could otherwise act as you; any other is told so. On a network where everyone may, start it with `--permissive`. `--no-web` turns the web client off. It answers only by an IP address, a `.local` or single-word name, or `localhost`, so another website can't use it from your browser.
* **Download** brings a movie or an episode to the browser's own computer.
* **Keep** (with `--downloads`) has the server keep a title, as the Mac downloads one, so your other devices play it from there.
* **Changes** (what's watched, your lists) reach your other devices a few seconds after you stop making them.
* **More,** for the curious: [cli/README.md](../cli/README.md#in-a-browser).
