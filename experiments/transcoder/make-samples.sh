#!/bin/zsh
# Makes 60-second, 720p test videos whose streams exercise each of the
# transcoder's paths: remux, remux with a retag, audio or subtitle conversion,
# and a video re-encode.
set -eu
out=${1:-/tmp/cinematheque-samples}
mkdir -p "$out"
cd "$out"

video=(-f lavfi -i testsrc2=size=1280x720:rate=24:duration=60)
audio=(-f lavfi -i sine=frequency=440:sample_rate=48000:duration=60 -ac 6)
cat > subs.srt <<'EOF'
1
00:00:01,000 --> 00:00:05,000
Hello, perihelion.

2
00:00:10,000 --> 00:00:15,000
Open the pod bay doors, hal.
EOF

ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }

# Plays on Apple players once remuxed into MP4.
ff $video $audio -map 0 -map 1 -c:v libx264 -preset veryfast -c:a aac -b:a 384k "H.264 AAC.mkv"
# HEVC tagged hev1, which Apple players reject until retagged hvc1.
ff $video $audio -map 0 -map 1 -c:v libx265 -preset ultrafast -tag:v hev1 -x265-params log-level=error -c:a ac3 "HEVC AC-3.mkv"
# DTS audio must be converted; the video can be copied.
ff $video $audio -map 0 -map 1 -c:v libx264 -preset veryfast -c:a dca -strict -2 "H.264 DTS.mkv"
# SubRip subtitles must become mov_text.
ff $video $audio -i subs.srt -map 0 -map 1 -map 2 -c:v libx264 -preset veryfast -c:a eac3 -c:s srt "H.264 E-AC-3 SRT.mkv"
# MPEG-2 video must be re-encoded.
ff $video $audio -map 0 -map 1 -c:v mpeg2video -q:v 4 -c:a ac3 "MPEG-2 AC-3.mkv"
rm subs.srt
ls -l "$out"
