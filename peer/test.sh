#!/bin/zsh
# Peer test: peer A founds a library, serves a generated source as
# media, and crawls it; peer B pairs to join, syncs, and must match A
# exactly; a change on A reaches B through discovery, and one on B reaches
# A by push; C, paired then removed, is refused; and B's progress reaches
# B's other device, B2 (paired to be B's), only directly.
set -eu
here=${0:A:h}
work=${1:-/tmp/cinematheque-peer-test}
peer=$here/zig-out/bin/cinematheque
gen=$here/zig-out/bin/gen

(cd $here && zig build --release=fast && zig build gen --release=fast)
rm -rf $work
mkdir -p $work

$gen $work/media 10
a=(--home $work/a)
b=(--home $work/b)
b2=(--home $work/b2)
c=(--home $work/c)
peer_pid=
b_pid=
d_pid=
cleanup() {
    kill ${peer_pid:-} ${b_pid:-} ${d_pid:-} 2> /dev/null || true
}
trap cleanup EXIT
digest() { $peer "$@" library show | awk '/^digest/ { print $2 }' }
# Pairs a new device ($1, a home) offering by $2 (`person pair` or `library
# join`) with a member's ($3), which sends the code by $4 (`person pair` or
# `member pair`), at the port the offer prints.
pair() {
    local log=$work/pair.log
    $peer --home $1 ${=2} > $log 2>&1 &
    local offer_pid=$!
    for _ in {1..100}; do grep -q "on port" $log && break; sleep 0.1; done
    local code=$(grep -o '[0-9]\{6\}$' $log)
    local port=$(grep -o 'on port [0-9]*' $log | grep -o '[0-9]*$')
    $peer --home $3 ${=4} $code http://127.0.0.1:$port/pair
    wait $offer_pid
}

$peer $a library create
$peer $a serve --port 8191 --media $work/media > $work/a.log 2>&1 &
peer_pid=$!
sleep 1
file=$(curl -sf http://127.0.0.1:8191/INDEX | awk -F'\t' 'NF > 1 { print $1; exit }' | sed 's|^\./||; s| |%20|g')
[[ $(curl -s -r 0-0 -o /dev/null -w "%{http_code}" "http://127.0.0.1:8191/$file") == 206 ]] || { echo "FAIL: no byte ranges from $file"; exit 1; }
$peer $a source add http://127.0.0.1:8191/
$peer $a crawl

pair $work/b "library join" $work/a "member pair"
$peer $b sync http://127.0.0.1:8191
[[ $(digest $a) == $(digest $b) ]] || { echo "FAIL: B differs from A after sync"; exit 1; }

$peer $a alias add t/m/movie-0001/1921 t/m/movie-0002/1922
$peer $b sync
[[ $(digest $a) == $(digest $b) ]] || { echo "FAIL: B differs from A after a change"; exit 1; }
$peer $b ls "Movie 0001"
$peer $b alias list | grep -q "movie-0001/1921 -> " || { echo "FAIL: alias list"; exit 1; }
$peer $a alias remove t/m/movie-0001/1921
$peer $b sync http://127.0.0.1:8191
$peer $b alias list | grep -q . && { echo "FAIL: alias remove"; exit 1; }
[[ $($peer $b member list | wc -l) -eq 2 ]] || { echo "FAIL: member list"; exit 1; }
# B's change reaches A by B's push, A pulling nothing.
$peer $b alias add t/m/movie-0004/1924 t/m/movie-0005/1925
$peer $b sync http://127.0.0.1:8191 | grep -q " [1-9][0-9]* pushed" || { echo "FAIL: B pushed nothing"; exit 1; }
$peer $a alias list | grep -q "movie-0004/1924 -> " || { echo "FAIL: B's push didn't reach A"; exit 1; }

pair $work/c "library join" $work/a "member pair"
$peer $a member remove $($peer $c person show)
$peer $c sync http://127.0.0.1:8191 | grep -q NotAMember || { echo "FAIL: a removed member was served"; exit 1; }

item=t/m/movie-0003/1923/v/-
pair $work/b2 "person pair" $work/b "person pair"
$peer $b progress set $item 600 6000
# B's pushes to A, another person's device, leave out B's progress.
$peer $b sync http://127.0.0.1:8191
$peer $a show ${item%/v/-} | grep -q " at " && { echo "FAIL: B pushed its progress to another person"; exit 1; }
$peer $b serve --port 8192 > $work/b.log 2>&1 &
b_pid=$!
sleep 1
$peer $a sync http://127.0.0.1:8192
$peer $a show ${item%/v/-} | grep -q " at " && { echo "FAIL: another person got B's progress"; exit 1; }
$peer $b2 sync http://127.0.0.1:8191
$peer $b2 show ${item%/v/-} | grep -q " at " && { echo "FAIL: B2 got B's progress through A"; exit 1; }
$peer $b2 sync http://127.0.0.1:8192
$peer $b2 show ${item%/v/-} | grep " at " || { echo "FAIL: B2 didn't get B's progress from B"; exit 1; }
$peer $b2 progress remove $item
$peer $b2 progress list | grep -q . && { echo "FAIL: progress remove"; exit 1; }
# B removes B2, which is told so, signed, when it next syncs; it leaves,
# and could pair again as a new device.
$peer $b2 sync http://127.0.0.1:8192 > /dev/null
b2_device=$($peer $b device list | grep -v "this device" | awk '{ print $1 }' | head -1)
$peer $b device remove $b2_device
$peer $b2 sync http://127.0.0.1:8192 | grep -q Removed || { echo "FAIL: a removed device wasn't told"; exit 1; }
$peer $b2 library leave
$peer $b2 library show 2>&1 | grep -q NoLibrary || { echo "FAIL: library leave"; exit 1; }

source=$($peer $a source list | cut -d" " -f1)
$peer $a source set $source --rendition "Test 720p"
$peer $a crawl $source --workers 4
$peer $a source show $source | grep -q 'rendition  "Test 720p"' || { echo "FAIL: source set"; exit 1; }
$peer $a show t/m/movie-0003/1923 | grep -q test-720p || { echo "FAIL: source set didn't move copies"; exit 1; }
# Two peers without --port: one may get 8008, the other must fall back.
$peer $c serve > $work/c1.log 2>&1 &
c1_pid=$!
$peer $c serve > $work/c2.log 2>&1 &
c2_pid=$!
sleep 1
kill $c1_pid $c2_pid
p1=$(grep -o "on port [0-9]*" $work/c1.log)
p2=$(grep -o "on port [0-9]*" $work/c2.log)
[[ -n $p1 && -n $p2 && $p1 != $p2 ]] || { echo "FAIL: no fallback port ($p1, $p2)"; exit 1; }

# Two drives' mount points under served media: one unplugged is unavailable (one
# marker), its copy kept, even over a restart; plugged back in, the marker
# goes; forgotten, its copy goes.
d=(--home $work/d)
mkdir -p $work/drives/archive0001 $work/drives/archive0002
cp "$work/media/$(cd $work/media && find . -name '*.mkv' | head -1)" "$work/drives/archive0001/Archive Movie (2001).mkv"
cp "$work/media/$(cd $work/media && find . -name '*.mkv' | head -1)" "$work/drives/archive0002/Other Movie (2002).mkv"
$peer $d library create
drives() {
    kill ${d_pid:-} 2> /dev/null || true
    $peer $d serve --port 8194 --media $work/drives > $work/d.log 2>&1 &
    d_pid=$!
    sleep 1
}
drives
$peer $d source add http://127.0.0.1:8194/
$peer $d crawl > /dev/null
rm "$work/drives/archive0001/Archive Movie (2001).mkv"
drives
$peer $d crawl | grep -q "1 directories unavailable" || { echo "FAIL: an unplugged drive wasn't unavailable"; exit 1; }
$peer $d source show http://127.0.0.1:8194/ | grep -q "copies     2" || { echo "FAIL: an unplugged drive's copy went"; exit 1; }
$peer $d source show http://127.0.0.1:8194/ | grep -q "unavailable     /archive0001" || { echo "FAIL: source show"; exit 1; }
cp "$work/media/$(cd $work/media && find . -name '*.mkv' | head -1)" "$work/drives/archive0001/Archive Movie (2001).mkv"
drives
$peer $d crawl | grep -q "0 directories unavailable" || { echo "FAIL: a drive back stayed unavailable"; exit 1; }
rm "$work/drives/archive0001/Archive Movie (2001).mkv"
drives
$peer $d crawl > /dev/null
$peer $d source forget http://127.0.0.1:8194/ /archive0001
$peer $d source show http://127.0.0.1:8194/ | grep -q "copies     1" || { echo "FAIL: source forget"; exit 1; }
kill $d_pid

$peer $c peer add http://127.0.0.1:8191
$peer $c peer list | grep -q "8191/sync  added" || { echo "FAIL: peer add"; exit 1; }
$peer $c peer remove http://127.0.0.1:8191
$peer $c peer list | grep -q added && { echo "FAIL: peer remove"; exit 1; }

# A downloads a movie under its path in the source, resumes one cut short,
# and keeps one already whole: a small file, real, from a server of its
# own (the generated source's are sparse, up to 40 GB each, which a
# download would write out in full).
small="Small Movie (1999)/Small Movie (1999).mp4"
mkdir -p "$work/small/${small%/*}"
head -c 300000 /dev/urandom > "$work/small/$small"
$peer $a serve --port 8195 --media $work/small > $work/small.log 2>&1 &
d_pid=$!
sleep 1
$peer $a source add http://127.0.0.1:8195/ > /dev/null
$peer $a crawl http://127.0.0.1:8195/ > /dev/null
movie=t/m/small-movie/1999
$peer $a title download $movie --to $work/dl > /dev/null
cmp -s "$work/dl/$small" "$work/small/$small" || { echo "FAIL: title download"; exit 1; }
head -c 1000 "$work/small/$small" > "$work/dl/$small.part"; rm "$work/dl/$small"
$peer $a title download $movie --to $work/dl | grep -q "done$" || { echo "FAIL: download resumed"; exit 1; }
cmp -s "$work/dl/$small" "$work/small/$small" && [ ! -e "$work/dl/$small.part" ] || { echo "FAIL: download resumed whole"; exit 1; }
$peer $a title download $movie --to $work/dl | grep -q "already here$" || { echo "FAIL: download kept"; exit 1; }
kill $d_pid
echo PASS
