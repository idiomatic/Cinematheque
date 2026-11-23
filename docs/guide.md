# Using Cinematheque

The details behind the [README](../README.md), for when you want them.

## Opening a download on a Mac

* **Control-click › Open** no longer gets past macOS's check since macOS 15; use System Settings' Open Anyway, as the README says.
* **A file fetched with `curl`** carries no quarantine mark, so it needs no clearing.

## Refreshing

* **Order:** Refresh Library (⌘R on the Mac) catches up with your other devices first, as they do on their own anyway, then looks through your sources.
* **Looking:** it reads each source's listings, recognizes titles from file and folder names, and records each file as a copy of its title, in its quality.
* **Later looks** reread only the folders that changed; Refresh Library Fully (⌥⌘R) rereads them all, as retagging a file doesn't change its folder.
* **Renamed or moved files** keep their place in the library, as long as the name still says the same title.
* **Unplugged drives:** when a folder's drive is unplugged or its share unmounted, its videos stay in the library, dimmed, until it's back, a year passes, or you remove them in Settings › Sources.
* **Removing a source** removes its copies on every device, so titles it alone held stop showing; its files stay where they are.

## Naming

* **Specials:** a file without an episode number beside a series' episodes, named for the series (`Worldhoppers The Lost Signal`), or in a `Specials` folder, is one of the series' specials.
* **Dated videos:** the ID tag keeps two videos of one day apart. The words between the date and the tag are the video's title, for browsing the folder, and aren't read for a year or an episode code. yt-dlp writes such names with this output template:

  ```
  %(channel)s/%(channel)s %(upload_date>%Y-%m-%d)s %(title).150B [youtube-%(id)s].%(ext)s
  ```

* **Inconsistent names** (a year off by one, a title spelled two ways, a file copied twice): the command-line app's review lists what looks related, and an alias, recorded once, tells every device that two entries are the same title; see [cli/README.md](../cli/README.md#titles).

## Watching

* **Resuming:** a season plays on from the episode you're partway through, else its next unwatched one.
* **Starting over:** stopping within the first 10 seconds forgets where you were, so going back to the start sticks.
* **Covers and descriptions** come from your sources:
  * a `poster.jpg` beside a movie, or a `season01-poster.jpg` beside a series, if you keep them;
  * else the cover and details your MP4 files carry, as HandBrake, iTunes, and tagging tools write them.
* **Before a cover loads,** its tile shows a blurred likeness of it, which travels with the library, so even a newly paired device shows one at once.
* **Lists,** like what you've watched, are yours alone unless you share one with everyone in the library.
* **In a browser:** see [below](#in-a-browser).

## In a browser

The command-line app can serve a web client, so any computer on your network browses and plays the library in a browser, with nothing installed. It runs on a computer that stays on: a home server, a NAS that runs Linux, or a Mac.

1. **Get the command-line app** onto that computer (see [Getting it](../README.md#getting-it)).
2. **Give it a library,** one of two ways:
   * **Join yours.** On it, offer to be added; it prints a code and waits:

     ```sh
     cinematheque person pair
     ```

     On one of your devices already in the library, enter the code, adding it as yours:
     * **A Mac:** in Settings › Devices › New Devices, then choose Yours.
     * **An Apple TV:** in Settings › Your Devices › Add a Device.
     * **The command-line app:** `cinematheque person pair CODE`.

     The browser will act as this device's person, so add it from a device of whoever watches there.
   * **Or, with no library yet, start one** on it:

     ```sh
     cinematheque library create
     ```
3. **Serve the web client.** Optionally, also serve a folder of videos from it (`--media`), and keep downloads there for your other devices (`--downloads`):

   ```sh
   cinematheque serve --web --media /srv/videos --downloads /srv/kept
   ```

   Once listening, it prints the web client's address.
4. **Add its folder as a source,** if you served one, from another terminal on it:

   ```sh
   cinematheque source add http://hal.local:8008/media/
   cinematheque crawl
   ```

5. **Open it** in a browser on your network: `http://hal.local:8008/`, by the computer's `.local` name or its IP address.
6. **Keep it running** in the background, as [cli/README.md](../cli/README.md#in-the-background) says, so it's there whenever someone opens it.

What to know:

* **Anyone who can reach the port** can use it, as that person, so it's off unless you give `--web`. It answers only by an IP address, a `.local` or single-word name, or `localhost`, so another website can't use it from your browser.
* **What plays:** browsers play MP4, M4V, and MOV files, not MKV or ISO.
* **Download** brings a movie or an episode to the browser's own computer.
* **Keep** (with `--downloads`) has the server keep a title, as the Mac downloads one, so your other devices play it from there.
* **Changes** (what's watched, your lists) reach your other devices a few seconds after you stop making them.
* **On a Mac,** start it from Terminal, which macOS can allow onto your local network (in System Settings › Privacy & Security › Local Network); without it, the server can't reach your NAS or your other devices.
* **More,** for the curious: [cli/README.md](../cli/README.md#in-a-browser).

## Downloading

* **Space:** the Download menu gives each choice's size and the space available for downloads: what's free, less the 20 GB Cinematheque always leaves free. It warns when a choice wouldn't fit.
* **While something streams,** downloads wait, so as not to slow it.
* **Sharing:** your downloads are a source like any other, so your other devices play from them.
* **What stays:** what you download yourself stays until you delete it.
* **What goes:** a series' episodes you've watched are deleted when their space is needed (unless you chose All), but only if a source still holds the same file, never the only copy.
* **Deleting by hand:** the trash button beside the Download controls, which asks first if any is the only copy.

## Sharing a library

* **Whose device:** when you add a device, choose yours to use the library as yourself, with your progress and lists, or someone new's, who joins as a member.
* **The code** seals what's sent, so only the device showing it can open it. The new device stops answering an address after 3 wrong tries from it, and everyone after 30, until it offers a new code.
* **Off your network,** or from the command line: see [cli/README.md](../cli/README.md#sharing-a-library).
* **When devices sync:** while an app runs, it syncs a minute after it last did, whenever it comes to the front, and a second after you make a change.
* **Trust:** each device checks, by signature, that every change comes from a member, so a device that relays the library can't alter it. Each serves the library only to members' devices.
* **Removing** a member stops their later changes everywhere, while what they did before stands; removing one of your devices does the same for that device.
