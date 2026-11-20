#!/bin/sh
# Downloads a YouTube channel's (or playlist's) videos into DIRECTORY (the
# current one, if not given) as a folder Cinematheque reads as a series:
# a season a year, an episode a day uploaded. See README.md.
set -eu
[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: $0 URL [DIRECTORY]" >&2; exit 2; }
mkdir -p "${2:-.}"
cd "${2:-.}"
exec yt-dlp -t mp4 --embed-metadata --embed-thumbnail --convert-thumbnails jpg \
    --download-archive .yt-dlp-archive \
    -o '%(channel)s/%(channel)s %(upload_date>%Y-%m-%d)s %(title).150B [youtube-%(id)s].%(ext)s' "$1"
