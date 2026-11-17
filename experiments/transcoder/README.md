# Transcoder experiment

Tests the transcoder's **Remux first** rule in [DEVELOPMENT.md](../../DEVELOPMENT.md): probe each input over HTTP, remux straight from the repository when the video plays on Apple players (converting only audio or subtitles), and otherwise cache the input and re-encode it with `HandBrakeCLI`, both tools run as separate processes.

## Running

```sh
./make-samples.sh /tmp/cinematheque-samples              # five 60-second test videos
../repository/zig-out/bin/repo serve /tmp/cinematheque-samples 8094
zig build test && zig build --release=fast
./zig-out/bin/transcode /tmp/cinematheque-out /tmp/cinematheque-cache "http://127.0.0.1:8094/H.264%20DTS.mkv" ...
swift playable.swift /tmp/cinematheque-out/*.mp4         # ask AVFoundation
```

Needs `ffmpeg`, `ffprobe`, and `HandBrakeCLI` on the path.

## Design

* [make-samples.sh](make-samples.sh): 720p, 24 fps, 5.1 audio, in MKV: H.264 with AAC; HEVC with AC-3; H.264 with DTS; H.264 with E-AC-3 and SubRip subtitles; and MPEG-2 with AC-3.
* [src/main.zig](src/main.zig): reads `ffprobe`'s JSON, plans each stream (copy; copy and retag HEVC `hvc1`; DTS, TrueHD, and other audio to E-AC-3 above two channels, else AAC; text subtitles to `mov_text`; image subtitles dropped; other video re-encoded), then either runs `ffmpeg` on the URL with `-movflags +faststart`, or copies the input to a cache by resumable range requests and runs `HandBrakeCLI --preset "Apple 1080p30 Surround" --optimize`. It checks the output's codec tags and that its `moov` box precedes `mdat`.
* [playable.swift](playable.swift): asks AVFoundation whether each file or URL, and each track, is playable.

## Results

Apple M2, macOS 27.2, ffmpeg 9.0.2, HandBrakeCLI 1.11.2, inputs served over loopback by [the repository server](../repository/README.md):

| Input | Plan | Time | Output | AVFoundation |
|---|---|---|---|---|
| H.264, AAC | remux | 0.16 s | `avc1`, `mp4a` | playable |
| HEVC, AC-3 | remux, retag `hvc1` | 0.09 s | `hvc1`, `ac-3` | playable |
| H.264, DTS 5.1 | remux, audio to E-AC-3 | 0.38 s | `avc1`, `ec-3` | playable |
| H.264, E-AC-3, SubRip | remux, subtitles to `mov_text` | 0.09 s | `avc1`, `ec-3`, `tx3g` | playable, with subtitles |
| MPEG-2, AC-3 | cache 58 MB, re-encode | 8.5 s | `avc1`, `mp4a`, `ac-3` | playable |

Every output has its index first. AVFoundation can't open the MKV inputs, and the HEVC remux played over HTTP from the repository server, byte ranges and all.

## Findings

* **Remuxing is nearly free** and streams straight from the repository: about 100 times faster than real time here, bound by I/O, so most "transcodes" of a typical library cost seconds, not hours.
* **The `hvc1` tag is decisive:** the same HEVC remuxed without retagging comes out `hev1`, and AVFoundation reports its video track unplayable.
* **Audio is the common blocker:** DTS converts to E-AC-3 while the video is copied, keeping the remux cheap.
* **HandBrake's Apple presets add a stereo AAC track** before the surround pass-through, which suits players without surround output.
* **Not yet tested:** 4K, 10-bit and HDR (HDR10, Dolby Vision profiles 7 and 8), PGS subtitles, real network speeds, disc images, and long inputs.
