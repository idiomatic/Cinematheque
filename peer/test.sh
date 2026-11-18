#!/bin/zsh
# Peer test: peer A founds a library, serves a generated repository as
# media, and crawls it; peer B pairs to join, syncs, and must match A
# exactly; a change on A reaches B through discovery, and one on B reaches
# A by push; C, paired then removed, is refused; and B's playhead reaches
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
cleanup() {
    kill ${peer_pid:-} ${b_pid:-} 2> /dev/null || true
}
trap cleanup EXIT
digest() { $peer "$@" library show | awk '/^digest/ { print $2 }' }
# Pairs a new device ($1, a home) offering by $2 (`user pair` or `library
# join`) with a member's ($3), which sends the code by $4 (`user pair` or
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
file=$(curl -sf http://127.0.0.1:8191/INDEX | head -1 | cut -f1 | sed 's|^\./||; s| |%20|g')
[[ $(curl -s -r 0-0 -o /dev/null -w "%{http_code}" "http://127.0.0.1:8191/$file") == 206 ]] || { echo "FAIL: no byte ranges from $file"; exit 1; }
$peer $a repo add http://127.0.0.1:8191/
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
$peer $a member remove $($peer $c user show)
$peer $c sync http://127.0.0.1:8191 | grep -q NotAMember || { echo "FAIL: a removed member was served"; exit 1; }

item=t/m/movie-0003/1923/v/-
pair $work/b2 "user pair" $work/b "user pair"
$peer $b playhead set $item 600 6000
# B's pushes to A, another user's device, leave out B's playheads.
$peer $b sync http://127.0.0.1:8191
$peer $a show ${item%/v/-} | grep -q " at " && { echo "FAIL: B pushed its playhead to another user"; exit 1; }
$peer $b serve --port 8192 > $work/b.log 2>&1 &
b_pid=$!
sleep 1
$peer $a sync http://127.0.0.1:8192
$peer $a show ${item%/v/-} | grep -q " at " && { echo "FAIL: another user got B's playhead"; exit 1; }
$peer $b2 sync http://127.0.0.1:8191
$peer $b2 show ${item%/v/-} | grep -q " at " && { echo "FAIL: B2 got B's playhead through A"; exit 1; }
$peer $b2 sync http://127.0.0.1:8192
$peer $b2 show ${item%/v/-} | grep " at " || { echo "FAIL: B2 didn't get B's playhead from B"; exit 1; }
$peer $b2 playhead remove $item
$peer $b2 playhead list | grep -q . && { echo "FAIL: playhead remove"; exit 1; }

repo=$($peer $a repo list | cut -d" " -f1)
$peer $a repo set $repo --rendition "Test 720p"
$peer $a crawl $repo --workers 4
$peer $a repo show $repo | grep -q 'rendition  "Test 720p"' || { echo "FAIL: repo set"; exit 1; }
$peer $a show t/m/movie-0003/1923 | grep -q test-720p || { echo "FAIL: repo set didn't move copies"; exit 1; }
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

$peer $c peer add http://127.0.0.1:8191
$peer $c peer list | grep -q "8191/sync  added" || { echo "FAIL: peer add"; exit 1; }
$peer $c peer remove http://127.0.0.1:8191
$peer $c peer list | grep -q added && { echo "FAIL: peer remove"; exit 1; }
echo PASS
