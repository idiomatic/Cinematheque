#!/bin/zsh
# Makes a mock library in DIRECTORY, for screenshots and demos: movies and
# series of the serials in Martha Wells's Murderbot Diaries (their names
# alone; every other word here is this script's own), each a silent video
# of one color, tagged as the core reads MP4s, with covers. With --data,
# also a data directory whose library has crawled it, with progress and
# lists. The same every run. See README.md.
set -eu
here=${0:A:h}
script=$0
cq=$here/../cli/zig-out/bin/cinematheque
# Written in every directory this script makes, so only those are cleared.
mark=.cinematheque-mock

usage() {
    echo "usage: $script [--data DATA] [--port PORT] DIRECTORY" >&2
    exit 2
}

dir= data= port=8642
while (( $# )); do
    case $1 in
        --data) (( $# >= 2 )) || usage; data=${2:A}; shift 2 ;;
        --port) (( $# >= 2 )) || usage; port=$2; shift 2 ;;
        -*) usage ;;
        *) [[ -z $dir ]] || usage; dir=${1:A}; shift ;;
    esac
done
[[ -n $dir ]] || usage
whence ffmpeg > /dev/null || { echo "error: no ffmpeg: install it (brew install ffmpeg)" >&2; exit 1 }

# Empties a directory this script made, or makes it; refuses any other.
claim() {
    if [[ -n $(ls -A -- $1 2> /dev/null) && ! -e $1/$mark ]]; then
        echo "error: refusing to overwrite $1: it isn't empty, and this script didn't make it" >&2
        exit 1
    fi
    rm -rf -- $1
    mkdir -p -- $1
    : > $1/$mark
}

claim $dir
[[ -z $data ]] || claim $data
tmp=$(mktemp -d)
serve_pid=
cleanup() {
    [[ -z $serve_pid ]] || kill $serve_pid 2> /dev/null || true
    rm -rf -- $tmp
}
trap cleanup EXIT

# The catalog is read twice: once for its covers (pass=cover), drawn all
# at once, then for its videos (pass=video).
pass=

# Dates a file as of a day, so the shelves' orders by date are the same
# every run.
stamp() { TZ=UTC touch -t ${2//-/}1200 -- $1 }

# A cover: its path (in DIRECTORY, or absolute), size, top and bottom
# colors, title, the line under it, and its date. Its art, if mock-art/
# has an image named for the title (and a season's line: `worldhoppers-
# season-1.jpg`), is drawn beneath the title; else the colors are.
covers=()
poster() {
    [[ $pass == cover ]] || return 0
    local out=$1 name=$6
    [[ $7 == Season* ]] && name+=" $7"
    name=${(L)name//[^[:alnum:]]/-}
    local art=$here/mock-art/$name.jpg
    [[ -e $art ]] || art=
    [[ $out == /* ]] || out=$dir/$out
    mkdir -p -- ${out:h}
    covers+=("$tmp/${#covers}.png"$'\t'$2$'\t'$3$'\t'$4$'\t'$5$'\t'$6$'\t'$7$'\t'$art$'\t'$out$'\t'$8)
}
# Shapes, as width and height.
tall=(600 900) square=(900 900)

# A silent video, a still of one color for its whole length (a 1-second
# frame rate keeps a movie's under a megabyte): its path, minutes, color,
# date, and a cover to embed (or -), then its tags as ffmpeg's -metadata.
video() {
    [[ $pass == video ]] || return 0
    local out=$dir/$1 minutes=$2 color=$3 date=$4 embed=$5
    shift 5
    local tags=() pic=()
    while (( $# )); do tags+=(-metadata "$1=$2"); shift 2; done
    [[ $embed == - ]] || pic=(-i $embed -map 0:v -map 1:v -c:v:1 copy -disposition:v:1 attached_pic)
    mkdir -p -- ${out:h}
    ffmpeg -v error -nostdin -y -f lavfi -i "color=c=0x${color}:s=320x180:r=1:d=$(( minutes * 60 ))" $pic \
        -an -c:v:0 libx264 -tune stillimage -pix_fmt yuv420p -threads 1 -g 600 \
        -map_metadata -1 -fflags +bitexact -flags:v +bitexact $tags $out
    stamp $out $date
}

# A movie: its file (under Movies, without .mp4), title, release date,
# minutes, color, genre, and description; embed=COVER embeds one. Each is in
# a folder of its own, named for the title and year (as Plex lays movies
# out), its poster.jpg beside it; its quality is 1080p, as its name says,
# unless the name gives another.
embed=-
movie() {
    local name=$1
    [[ $name == */* ]] || name="${name%%)*})/$name"
    [[ $name == *[0-9]p* ]] || name+=" 1080p"
    video Movies/$name.mp4 $4 $5 $3 $embed title $2 date $3 genre $6 description $7 synopsis $7
}

# A series, which episode and dated add to: its name, genre, network, and
# color.
series() { show=$1 genre=$2 network=$3 color=$4 }
# An episode: season (0 for a special), number, air date, minutes, title,
# and description.
episode() {
    local file
    if (( $1 == 0 )); then
        file=$(printf 'Series/%s/Specials/%s S00E%02d 1080p.mp4' $show $show $2)
    else
        file=$(printf 'Series/%s/Season %02d/%s S%02dE%02d 1080p.mp4' $show $1 $show $1 $2)
    fi
    video $file $4 $color $3 - title $5 description $6 synopsis $6 genre $genre date $3 \
        show $show network $network season_number $1 episode_sort $2
}
# An episode of a dated series (a season a year): air date, minutes, title,
# and description.
dated() {
    video "Series/$show/$show $1 720p.mp4" $2 $color $1 - title $3 description $4 synopsis $4 genre $genre date $1 \
        show $show network $network
}

catalog() {
    poster "Movies/Hostile Survey (2021)/poster.jpg" $tall 2f5d7a 0b1520 "Hostile Survey" 2021 2021-04-16
    movie "Hostile Survey (2021)" "Hostile Survey" 2021-04-16 104 2f5d7a Thriller \
        "A survey team on a quiet planet comes to suspect its security unit knows more than it says."
    movie "Hostile Survey (2021) - Director's Cut" "Hostile Survey" 2021-04-16 118 2f5d7a Thriller \
        "A survey team on a quiet planet comes to suspect its security unit knows more than it says, with the long version of the final stand."

    # Two qualities, in a folder of their own, its poster theirs.
    poster "Movies/Wormhole Drift (2024)/poster.jpg" $tall 6b3fa0 120a2e "Wormhole Drift" 2024 2024-08-09
    movie "Wormhole Drift (2024)/Wormhole Drift (2024) - 1080p" "Wormhole Drift" 2024-08-09 126 6b3fa0 "Science Fiction" \
        "A freighter crew loses a week inside a wormhole and comes out carrying a passenger."
    movie "Wormhole Drift (2024)/Wormhole Drift (2024) - 2160p HDR" "Wormhole Drift" 2024-08-09 126 6b3fa0 "Science Fiction" \
        "A freighter crew loses a week inside a wormhole and comes out carrying a passenger."

    # Its cover embedded in the file, with no sidecar.
    poster $tmp/gate.jpg $tall c2703d 3a1606 "The Last Gate Station" 2019 2019-11-22
    embed=$tmp/gate.jpg movie "The Last Gate Station (2019)" "The Last Gate Station" 2019-11-22 97 c2703d Drama \
        "The last keeper of a retired jump gate won't leave until the final ship comes through."

    poster "Movies/The Long Haul Contract (2025)/poster.jpg" $tall 2e8b57 0d2618 "The Long Haul Contract" 2025 2025-06-13
    movie "The Long Haul Contract (2025)" "The Long Haul Contract" 2025-06-13 112 2e8b57 Adventure \
        "Two rival pilots share a cockpit for a cargo run nobody else would take."

    poster "Movies/Hold the Corridor (2020)/poster.jpg" $tall a3262a 2a0709 "Hold the Corridor" 2020 2020-07-10
    movie "Hold the Corridor (2020)" "Hold the Corridor" 2020-07-10 95 a3262a Action \
        "A lone guard and a class of students wait out a raid on a transit hub."

    poster "Movies/Quiet Orbit (2022)/poster.jpg" $tall d4789c 3b1430 "Quiet Orbit" 2022 2022-02-11
    movie "Quiet Orbit (2022)" "Quiet Orbit" 2022-02-11 101 d4789c Romance \
        "Two station engineers fall for each other one maintenance shift at a time."

    # The long-running one: a season's cover beside it, one in its folder,
    # and one taking the series'.
    series "The Rise and Fall of Sanctuary Moon" Drama "Ringside Media" 1d6f73
    poster "Series/$show/poster.jpg" $tall 1d6f73 2b1048 $show "" 2019-03-04
    poster "Series/$show/season01-poster.jpg" $square 1d6f73 0c2c3a "Sanctuary Moon" "Season 1" 2019-03-04
    poster "Series/$show/Season 02/poster.jpg" $square 2b1048 12061f "Sanctuary Moon" "Season 2" 2020-02-03
    episode 1 1 2019-03-04 42 "Arrival Day" "A new administrator steps off the shuttle and into a feud older than the station."
    episode 1 2 2019-03-11 42 "Dock Seven" "A cargo manifest doesn't add up, and the night shift knows why."
    episode 1 3 2019-03-18 42 "The Solicitor's Offer" "An off-world lawyer makes the colony an offer it can't afford to refuse."
    episode 1 4 2019-03-25 42 "Eclipse Party" "The moon goes dark for an hour, and someone uses every minute of it."
    episode 2 1 2020-02-03 42 "Aftermath" "The colony counts what the eclipse cost, and who isn't answering."
    episode 2 2 2020-02-10 42 "Two Captains" "Rival haulers dock on the same morning, each with a claim on one berth."
    episode 2 3 2020-02-17 42 "The Hydroponics Affair" "A failing crop, a forged signature, and a romance nobody saw coming."
    episode 2 4 2020-02-24 42 "Lockdown" "A breach alarm seals the habitat ring with the wrong people inside."
    episode 0 1 2020-12-21 44 "A Station Holiday" "The colony gathers for a festival broadcast, its feuds set aside for one night."
    episode 3 1 2021-01-11 42 "New Management" "A takeover bid arrives by courier, signed by a name long thought dead."
    episode 3 2 2021-01-18 42 "The Long Shift" "The medical bay runs out of everything but patience."
    episode 3 3 2021-01-25 42 "Inheritance" "A will is read aloud, and half the station walks out."
    episode 3 4 2021-02-01 42 "Moonfall" "The administrator makes a choice that will echo for seasons."

    series Worldhoppers Adventure "Outer Feeds" d9622b
    poster "Series/$show/poster.jpg" $tall d9622b 5a1208 Worldhoppers "" 2022-05-02
    poster "Series/$show/season01-poster.jpg" $square d9622b 6e1f0b Worldhoppers "Season 1" 2022-05-02
    poster "Series/$show/season02-poster.jpg" $square e0a030 7a3a08 Worldhoppers "Season 2" 2023-06-05
    episode 1 1 2022-05-02 45 "First Jump" "A survey crew's untested drive lands them a long way from home."
    episode 1 2 2022-05-09 45 "The Glass Desert" "A planet of mirrors shows the crew more than their reflections."
    episode 1 3 2022-05-16 45 "Signal Lost" "With the beacon dead, the crew votes on whether to keep going."
    episode 2 1 2023-06-05 45 "Second Jump" "Repairs done, the crew tries the drive again, against advice."
    episode 2 2 2023-06-12 45 "Tidewater" "A world of endless ocean hides a city beneath its waves."
    episode 2 3 2023-06-19 45 "Homeward" "A course for home appears in the logs, and nobody put it there."

    # A miniseries, its cover square.
    series "Timestream Defenders Orion" "Science Fiction" "Archive Channel" 3c5fd6
    poster "Series/$show/Season 01/poster.jpg" $square 3c5fd6 0d1440 "Timestream Defenders Orion" "" 2024-09-02
    episode 1 1 2024-09-02 50 "Paradox Protocol" "A squad sworn to guard history wakes a century too early."
    episode 1 2 2024-09-09 50 "The Unwritten Year" "A missing year in the records turns out to be hiding a war."
    episode 1 3 2024-09-16 50 "Echo Fleet" "The squad meets its own future selves, who won't explain."
    episode 1 4 2024-09-23 50 "Orion Holds" "Everything rests on one defender keeping a single promise."

    # Its seasons taking the series' cover.
    series "Lineages of the Sun" "Historical Drama" "Heritage Feed" c9a227
    poster "Series/$show/poster.jpg" $tall c9a227 4a2a0a "Lineages of the Sun" "" 2023-10-02
    episode 1 1 2023-10-02 55 "The First Daughter" "A matriarch names an heir, and three cousins start counting allies."
    episode 1 2 2023-10-09 55 "Salt and Silver" "A trade marriage is arranged over the bride's objections."
    episode 1 3 2023-10-16 55 "The Burning Archive" "Fire takes the family records, and with them, a secret."
    episode 2 1 2025-03-03 55 "A House Divided" "The cousins split the estate, and the household with it."
    episode 2 2 2025-03-10 55 "Pilgrims" "A long road east tests a fragile truce."
    episode 2 3 2025-03-17 55 "Sunrise Court" "The lineage gathers to crown an heir no one expected."

    # A dated series, a season a year, its cover square.
    series "Ring Station Tonight" News "Ringside Media" 4a5560
    poster "Series/$show/poster.jpg" $square 4a5560 15191d "Ring Station Tonight" "" 2025-11-03
    dated 2025-11-03 22 "Docking Fees Rise Again" "Haulers protest the ring's new fees, and the night market answers."
    dated 2025-11-10 22 "The Night Market Reopens" "Stalls return to the lower ring after a month of repairs."
    dated 2026-01-05 22 "New Year on the Ring" "The station marks the year's turn with lights along the spokes."
    dated 2026-01-12 22 "A Pilot's Long Way Home" "A courier pilot lands after six years in the outer systems."
}

pass=cover catalog
mkdir -p $tmp
if whence swift > /dev/null; then
    print -l -- ${covers%$'\t'*$'\t'*} | swift $here/mock-covers.swift
else
    echo "no swift: covers without their titles" >&2
fi
for c in $covers; do
    f=("${(@ps:\t:)c}")
    if [[ -e $f[1] ]]; then
        ffmpeg -v error -nostdin -y -i $f[1] -frames:v 1 -q:v 3 -pix_fmt yuvj420p -fflags +bitexact -flags:v +bitexact $f[9]
    else
        ffmpeg -v error -nostdin -y -f lavfi -i "gradients=s=${f[2]}x${f[3]}:c0=0x${f[4]}:c1=0x${f[5]}:n=2:x0=0:y0=0:x1=0:y1=${f[3]}:speed=0" \
            -frames:v 1 -q:v 3 -pix_fmt yuvj420p -fflags +bitexact -flags:v +bitexact $f[9]
    fi
    stamp $f[9] $f[10]
done
pass=video catalog
echo "made a mock library in $dir"
[[ -n $data ]] || exit 0

# The library, crawled, with progress and lists, made through the web
# client's API, as the command-line app makes no lists.
[[ -x $cq ]] || (cd $here/../cli && zig build --release=safe)
d=(--data $data)
$cq $d library create
$cq $d serve --port $port --media $dir --web > $tmp/serve.log 2>&1 &
serve_pid=$!
for _ in {1..100}; do grep -q '^serving' $tmp/serve.log && break; sleep 0.1; done
grep -q '^serving' $tmp/serve.log || { cat $tmp/serve.log >&2; exit 1 }
$cq $d source add http://127.0.0.1:$port/media/
$cq $d crawl

moon=t/s/the-rise-and-fall-of-sanctuary-moon/-
hoppers=t/s/worldhoppers/-
watched() { for item; do $cq $d progress set $item --watched > /dev/null; done }
watched $moon/e/s01e0{1..4} $moon/e/s02e0{1,2} $hoppers/e/s01e01 t/m/wormhole-drift/2024/v/- \
    t/s/timestream-defenders-orion/-/e/s01e0{1..4}
$cq $d progress set $moon/e/s02e03 1260 2520 > /dev/null
$cq $d progress set $hoppers/e/s01e02 1500 2700 > /dev/null
$cq $d progress set t/m/hostile-survey/2021/v/- 3900 6240 > /dev/null

api() {
    curl -sSf -H 'content-type: application/json' -d $2 http://127.0.0.1:$port/api/$1
}
listed() { for key in ${@:2}; do api listed "{\"list\":\"$1\",\"key\":\"$key\",\"on\":true}" > /dev/null; done }
listed watchlist t/m/the-long-haul-contract/2025 t/s/lineages-of-the-sun/-#1 t/m/quiet-orbit/2022
api list-want '{"list":"watchlist","want":{"kind":"series","name":"Worldhoppers","season":3,"note":"The third jump, due next spring"}}' > /dev/null
api list-want '{"list":"watchlist","want":{"kind":"movie","name":"Station Siege","year":2026,"note":"Opens on the feeds next month"}}' > /dev/null
favorites=$(api list-create '{"name":"Favorites"}' | tr -d '"')
listed $favorites $moon#1 t/m/the-last-gate-station/2019 t/s/timestream-defenders-orion/-#1
kill $serve_pid
wait $serve_pid 2> /dev/null || true
serve_pid=
echo "made a library of it in $data; serve it again with:"
echo "  $cq --data $data serve --port $port --media $dir --web"
