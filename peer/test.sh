#!/bin/zsh
# Peer test: peer A founds a library, serves a generated repository as
# media, and crawls it; peer B joins, is invited, syncs, and must match A exactly; a
# change on A reaches B through discovery; a peer that isn't a member is
# refused; and B's playhead reaches B's other device, B2, only directly.
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

$peer $a library create
$peer $a serve --port 8191 --media $work/media > $work/a.log 2>&1 &
peer_pid=$!
sleep 1
file=$(curl -sf http://127.0.0.1:8191/INDEX | head -1 | cut -f1 | sed 's|^\./||; s| |%20|g')
[[ $(curl -s -r 0-0 -o /dev/null -w "%{http_code}" "http://127.0.0.1:8191/$file") == 206 ]] || { echo "FAIL: no byte ranges from $file"; exit 1; }
$peer $a repo add http://127.0.0.1:8191/
$peer $a crawl

$peer $b library join $($peer $a user show)
$peer $a member add $($peer $b user show)
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

$peer $c library join $($peer $a user show)
$peer $c sync http://127.0.0.1:8191 | grep -q NotAMember || { echo "FAIL: a non-member was served"; exit 1; }

item=t/m/movie-0003/1923/v/-
$peer $b2 user link $($peer $b user secret)
$peer $b2 library join $($peer $a user show)
$peer $b playhead set $item 600 6000
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
