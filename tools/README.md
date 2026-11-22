# Tools

Scripts that work alongside Cinematheque, outside the apps.

## Code debt

[debt.py](debt.py) reports declarations nothing uses (exiting 1 if any), files over 1,600 lines, and the spec's length in words, as [DEVELOPMENT.md](../DEVELOPMENT.md#practice)'s Practice asks before each push.

## YouTube

[youtube.sh](youtube.sh) downloads YouTube channels' videos (or playlists') with [yt-dlp](https://github.com/yt-dlp/yt-dlp) into a directory you then add as a source, each channel a folder that shows as a series: a season per year, an episode per upload, in date order.

```sh
tools/youtube.sh ~/Movies/YouTube 'https://www.youtube.com/@kurzgesagt/videos'
```

The URLs it's given are kept in the directory's `.yt-dlp-url`, one to a line, so given none, it fetches every one again for what's new:

```sh
tools/youtube.sh ~/Movies/YouTube
```

Only adding URLs changes the file (each kept once, `sort -u`); fetching again hands it to yt-dlp as is (`--batch-file`), which skips lines starting with `#`, so a URL can be set aside, or deleted, there. It notes what it has fetched in the directory's `.yt-dlp-archive`, so it skips those without asking YouTube about each. It needs yt-dlp and FFmpeg (`brew install yt-dlp ffmpeg`).

* **Format:** `-t mp4`, yt-dlp's preset for H.264 video and AAC audio in an MP4, which every player plays; YouTube offers H.264 up to 1080p.
* **Metadata:** `--embed-metadata` and `--embed-thumbnail` put each video's title, description, and thumbnail in its file, so describing finds them without sidecar files (the thumbnail as JPEG, for its placeholder). A season's cover is one of its videos' thumbnails.
* **Names:** `Channel/Channel 2024-03-12 The World in 2050 [youtube-ID].mp4`. The date makes it an episode, of the season 2024 (`e/s2024e0312`); the ID keeps two videos of a day apart, and the parser reads `[youtube-…]` as a tag, so nothing in it is taken for a year. The video's title (cut to 150 bytes, so the name stays within a file system's 255) is there for browsing the folder; the parser skips what comes between the date and the tag, so a year, part, or episode code in it isn't read as one.

Downloading from YouTube may be against its terms of service. That's for you to weigh; the apps never fetch from YouTube themselves.
