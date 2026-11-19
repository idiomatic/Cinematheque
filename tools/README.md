# Tools

Scripts that work alongside Cinematheque, outside the apps.

## YouTube

[youtube.sh](youtube.sh) downloads a YouTube channel's videos (or a playlist's) with [yt-dlp](https://github.com/yt-dlp/yt-dlp) into a folder you then add as a source, where they show as a series: a season per year, an episode per upload, in date order.

```sh
tools/youtube.sh 'https://www.youtube.com/@kurzgesagt/videos' ~/Movies/YouTube
```

Run it again to fetch what's new: it notes what it has fetched in the folder's `.yt-dlp-archive`, so it skips those without asking YouTube about each. It needs yt-dlp and FFmpeg (`brew install yt-dlp ffmpeg`).

* **Format:** `-t mp4`, yt-dlp's preset for H.264 video and AAC audio in an MP4, which every player plays; YouTube offers H.264 up to 1080p.
* **Metadata:** `--embed-metadata` and `--embed-thumbnail` put each video's title, description, and thumbnail in its file, so describing finds them without sidecar files (the thumbnail as JPEG, for its placeholder). A season's cover is one of its videos' thumbnails.
* **Names:** `Channel/Channel 2024-03-12 [youtube-ID].mp4`. The date makes it an episode, of the season 2024 (`e/s2024e0312`); the ID keeps two videos of a day apart, and the parser reads `[youtube-…]` as a tag, so nothing in it is taken for a year. The video's title stays out of the name, as a year or episode code in it would be read as one.

Downloading from YouTube may be against its terms of service. That's for you to weigh; the apps never fetch from YouTube themselves.
