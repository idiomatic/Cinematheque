#!/bin/sh
# Downloads YouTube channels' (or playlists') videos into DIRECTORY, each
# channel a folder Cinematheque reads as a series: a season a year, an
# episode a day uploaded. URLs given are kept in DIRECTORY's .yt-dlp-url,
# so given none, it fetches them all again for new uploads. See README.md.
set -eu

usage() {
    echo "usage: $0 DIRECTORY [URL ...]" >&2
    exit 2
}

[ $# -ge 1 ] || usage
case "$1" in -* | *://*) usage ;; esac
# Made only to fetch into.
[ $# -eq 1 ] || mkdir -p -- "$1"
cd -- "$1"
shift
if [ $# -gt 0 ]; then
    # Kept, each once, to fetch again; then just these fetched.
    printf '%s\n' "$@" >> .yt-dlp-url
    sort -u -o .yt-dlp-url .yt-dlp-url
    set -- -- "$@"
else
    [ -s .yt-dlp-url ] || { echo "error: $(pwd) has no .yt-dlp-url: fetch something first ($0 DIRECTORY URL)" >&2; exit 1; }
    set -- --batch-file .yt-dlp-url
fi
exec yt-dlp -t mp4 --embed-metadata --embed-thumbnail --convert-thumbnails jpg \
    --download-archive .yt-dlp-archive \
    -o '%(channel)s/%(channel)s %(upload_date>%Y-%m-%d)s %(title).150B [youtube-%(id)s].%(ext)s' "$@"
