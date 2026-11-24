#!/bin/zsh
# The command-line app, end to end: device A founds a library, serves a generated source as
# media, and crawls it; device B pairs to join, syncs, and must match A
# exactly; a change on A reaches B through discovery, and one on B reaches
# A by push; C, paired then removed, is refused; and B's progress reaches
# B's other device, B2 (paired to be B's), only directly.
set -eu

# The mock library's devices announce and look for their own service type,
# never seeing a person's own devices nor theirs them (see discover.zig).
export CINEMATHEQUE_DNSSD=_cinemock._tcp
here=${0:A:h}
work=${1:-/tmp/cinematheque-cli-test}
cq=$here/zig-out/bin/cinematheque
gen=$here/zig-out/bin/gen

(cd $here && zig build --release=safe && zig build gen --release=fast)
# Only a directory this test could have made is cleared.
if [[ -e $work && -n $(ls -A $work 2> /dev/null) && ${work:t} != cinematheque-cli-test* ]]; then
    echo "refusing to clear $work: not named cinematheque-cli-test..." >&2
    exit 1
fi
rm -rf $work
mkdir -p $work

$gen $work/media 10
a=(--data $work/a)
b=(--data $work/b)
b2=(--data $work/b2)
c=(--data $work/c)
a_pid=
b_pid=
d_pid=
c1_pid=
c2_pid=
cleanup() {
    kill ${a_pid:-} ${b_pid:-} ${c1_pid:-} ${c2_pid:-} ${d_pid:-} 2> /dev/null || true
}
trap cleanup EXIT
digest() { $cq "$@" library show | awk '/^digest/ { print $2 }' }
# Pairs a new device ($1, a data directory) offering by $2 (`person pair` or `library
# join`) with a member's ($3), which sends the code by $4 (`person pair` or
# `member pair`), at the port the offer prints.
pair() {
    local log=$work/pair.log
    $cq --data $1 ${=2} > $log 2>&1 &
    local offer_pid=$!
    for _ in {1..100}; do grep -q "on port" $log && break; sleep 0.1; done
    local code=$(grep -o 'code [0-9]\{6\}' $log | grep -o '[0-9]*$')
    local port=$(grep -o 'on port [0-9]*' $log | grep -o '[0-9]*$')
    $cq --data $3 ${=4} $code http://127.0.0.1:$port/pair
    wait $offer_pid
}

$cq $a library create
$cq $a serve --port 8191 --media $work/media > $work/a.log 2>&1 &
a_pid=$!
sleep 1
file=$(curl -sf http://127.0.0.1:8191/media/INDEX | awk -F'\t' 'NF > 1 { print $1; exit }' | sed 's|^\./||; s| |%20|g')
[[ $(curl -s -r 0-0 -o /dev/null -w "%{http_code}" "http://127.0.0.1:8191/media/$file") == 206 ]] || { echo "FAIL: no byte ranges from $file"; exit 1; }
$cq $a source add http://127.0.0.1:8191/media/
$cq $a crawl

pair $work/b "library join" $work/a "member pair"
$cq $b sync http://127.0.0.1:8191
[[ $(digest $a) == $(digest $b) ]] || { echo "FAIL: B differs from A after sync"; exit 1; }

$cq $a alias add t/m/movie-0001/1921 t/m/movie-0002/1922
$cq $b sync
[[ $(digest $a) == $(digest $b) ]] || { echo "FAIL: B differs from A after a change"; exit 1; }
$cq $b ls "Movie 0001"
# Help: a shortcut's alone; a bad command line exits with status 2.
[[ $($cq ls -h | grep -c '^  ') -gt 0 && -z $($cq ls -h | grep '^  title show') ]] || { echo "FAIL: ls -h"; exit 1; }
[[ -n $($cq show -h | grep '^  title show') && -z $($cq show -h | grep '^  title list') ]] || { echo "FAIL: show -h"; exit 1; }
$cq -h | grep -q "^Usage:" || { echo "FAIL: -h"; exit 1; }
set +e
$cq $b nonsense > /dev/null 2>&1
[[ $? -eq 2 ]] || { echo "FAIL: a bad command line didn't exit with status 2"; exit 1; }
set -e
$cq $b title facets | grep -q . || { echo "FAIL: title facets"; exit 1; }
$cq $b alias list | grep -q "movie-0001/1921 -> " || { echo "FAIL: alias list"; exit 1; }
$cq $a alias remove t/m/movie-0001/1921
$cq $b sync http://127.0.0.1:8191
$cq $b alias list | grep -q . && { echo "FAIL: alias remove"; exit 1; }
[[ $($cq $b member list | wc -l) -eq 2 ]] || { echo "FAIL: member list"; exit 1; }
# B's change reaches A by B's push, A pulling nothing.
$cq $b alias add t/m/movie-0004/1924 t/m/movie-0005/1925
$cq $b sync http://127.0.0.1:8191 | grep -q " [1-9][0-9]* pushed" || { echo "FAIL: B pushed nothing"; exit 1; }
$cq $a alias list | grep -q "movie-0004/1924 -> " || { echo "FAIL: B's push didn't reach A"; exit 1; }

pair $work/c "library join" $work/a "member pair"
$cq $a member remove $($cq $c person show)
$cq $c sync http://127.0.0.1:8191 | grep -q NotAMember || { echo "FAIL: a removed member was served"; exit 1; }

item=t/m/movie-0003/1923/v/-
pair $work/b2 "person pair" $work/b "person pair"
$cq $b progress set $item 600 6000
$cq $b progress set $item --watched
$cq $b progress list | grep -q "$item" || { echo "FAIL: progress set --watched"; exit 1; }
$cq $b progress set $item 600 6000
# B's pushes to A, another person's device, leave out B's progress.
$cq $b sync http://127.0.0.1:8191
$cq $a show ${item%/v/-} | grep -q " at " && { echo "FAIL: B pushed its progress to another person"; exit 1; }
$cq $b serve --port 8192 > $work/b.log 2>&1 &
b_pid=$!
sleep 1
$cq $a sync http://127.0.0.1:8192
$cq $a show ${item%/v/-} | grep -q " at " && { echo "FAIL: another person got B's progress"; exit 1; }
$cq $b2 sync http://127.0.0.1:8191
$cq $b2 show ${item%/v/-} | grep -q " at " && { echo "FAIL: B2 got B's progress through A"; exit 1; }
$cq $b2 sync http://127.0.0.1:8192
$cq $b2 show ${item%/v/-} | grep " at " || { echo "FAIL: B2 didn't get B's progress from B"; exit 1; }
$cq $b2 progress remove $item
$cq $b2 progress list | grep -q . && { echo "FAIL: progress remove"; exit 1; }
# B removes B2, which is told so, signed, when it next syncs; it leaves,
# and could pair again as a new device.
$cq $b2 sync http://127.0.0.1:8192 > /dev/null
b2_device=$($cq $b device list | grep -E '^[0-9a-f]{64}  ' | grep -v "this device" | awk '{ print $1 }' | head -1)
$cq $b device remove $b2_device
$cq $b2 sync http://127.0.0.1:8192 | grep -q Removed || { echo "FAIL: a removed device wasn't told"; exit 1; }
$cq $b2 library leave
$cq $b2 library show 2>&1 | grep -q "has no library" || { echo "FAIL: library leave"; exit 1; }

source=$($cq $a source list | cut -d" " -f1)
$cq $a source set $source --quality "Test 720p"
$cq $a crawl $source --workers 4
$cq $a source show $source | grep -q 'quality    "Test 720p"' || { echo "FAIL: source set"; exit 1; }
$cq $a show t/m/movie-0003/1923 | grep -q test-720p || { echo "FAIL: source set didn't move copies"; exit 1; }
# Two devices without --port: one may get 8008, the other must fall back.
$cq $c serve > $work/c1.log 2>&1 &
c1_pid=$!
$cq $c serve > $work/c2.log 2>&1 &
c2_pid=$!
sleep 1
kill $c1_pid $c2_pid
wait $c1_pid $c2_pid 2> /dev/null || true
p1=$(grep -o "on port [0-9]*" $work/c1.log)
p2=$(grep -o "on port [0-9]*" $work/c2.log)
[[ -n $p1 && -n $p2 && $p1 != $p2 ]] || { echo "FAIL: no fallback port ($p1, $p2)"; exit 1; }

# Two drives' mount points under served media: one unplugged is unavailable (one
# marker), its copy kept, even over a restart; plugged back in, the marker
# goes; forgotten, its copy goes.
d=(--data $work/d)
mkdir -p $work/drives/archive0001 $work/drives/archive0002
cp "$work/media/$(cd $work/media && find . -name '*.mkv' | head -1)" "$work/drives/archive0001/Archive Movie (2001).mkv"
cp "$work/media/$(cd $work/media && find . -name '*.mkv' | head -1)" "$work/drives/archive0002/Other Movie (2002).mkv"
$cq $d library create
drives() {
    if [[ -n ${d_pid:-} ]]; then
        kill $d_pid 2> /dev/null || true
        wait $d_pid 2> /dev/null || true
    fi
    $cq $d serve --port 8194 --media $work/drives > $work/d.log 2>&1 &
    d_pid=$!
    sleep 1
}
drives
$cq $d source add http://127.0.0.1:8194/media/
$cq $d crawl > /dev/null
rm "$work/drives/archive0001/Archive Movie (2001).mkv"
drives
$cq $d crawl | grep -q "1 directories unavailable" || { echo "FAIL: an unplugged drive wasn't unavailable"; exit 1; }
$cq $d source show http://127.0.0.1:8194/media/ | grep -q "copies     2" || { echo "FAIL: an unplugged drive's copy went"; exit 1; }
$cq $d source show http://127.0.0.1:8194/media/ | grep -q "unavailable     /archive0001" || { echo "FAIL: source show"; exit 1; }
cp "$work/media/$(cd $work/media && find . -name '*.mkv' | head -1)" "$work/drives/archive0001/Archive Movie (2001).mkv"
drives
$cq $d crawl | grep -q "0 directories unavailable" || { echo "FAIL: a drive back stayed unavailable"; exit 1; }
rm "$work/drives/archive0001/Archive Movie (2001).mkv"
drives
$cq $d crawl > /dev/null
$cq $d source remove http://127.0.0.1:8194/media/ --unavailable /archive0001
$cq $d source show http://127.0.0.1:8194/media/ | grep -q "copies     1" || { echo "FAIL: source remove --unavailable"; exit 1; }
kill $d_pid

# A device's own folder, added by its .local name and port as builds before
# wrote them, moves once to its port-free address (cqdevice://), keeping its
# copies; served on another port, it's the same source, its copies unwritten.
# Only where this computer's .local name resolves (mDNS).
e=(--data $work/e)
here=$(hostname -s).local
$cq $e library create
own() {
    $cq $e serve --port $1 --media $work/drives > $work/e.log 2>&1 &
    e_pid=$!
    sleep 1
}
own 8196
if curl -sf -m 5 -o /dev/null http://$here:8196/version; then
    $cq $e source add http://$here:8196/media/ > /dev/null
    $cq $e crawl > /dev/null
    kill $e_pid; wait $e_pid 2> /dev/null || true
    own 8197
    $cq $e source list | grep -q "cqdevice://" || { echo "FAIL: a device's own folder kept its port"; exit 1; }
    $cq $e source list | grep -q "$here" && { echo "FAIL: its old address stayed"; exit 1; }
    $cq $e crawl | grep -q "copies 0 added, 0 changed, 0 removed" || { echo "FAIL: its copies were written again"; exit 1; }
    copies=$($cq $e source show "$($cq $e source list | cut -d' ' -f1)" | grep "copies ")
    [[ $copies == *" 1" ]] || { echo "FAIL: its copies went ($copies)"; exit 1; }
else
    echo "skipped: $here doesn't resolve"
fi
kill $e_pid; wait $e_pid 2> /dev/null || true

$cq $c device add http://127.0.0.1:8191
$cq $c device list | grep -q "8191/sync  added" || { echo "FAIL: device add"; exit 1; }
$cq $c device forget http://127.0.0.1:8191
$cq $c device list | grep -q "  added" && { echo "FAIL: device forget"; exit 1; }

# A downloads a movie under its path in the source, resumes one cut short,
# and keeps one already whole: a small file, real, from a server of its
# own (the generated source's are sparse, up to 40 GB each, which a
# download would write out in full).
small="Small Movie (1999)/Small Movie (1999).mp4"
mkdir -p "$work/small/${small%/*}"
head -c 300000 /dev/urandom > "$work/small/$small"
$cq $a serve --port 8195 --media $work/small > $work/small.log 2>&1 &
d_pid=$!
sleep 1
$cq $a source add http://127.0.0.1:8195/media/ > /dev/null
$cq $a crawl http://127.0.0.1:8195/media/ > /dev/null
movie=t/m/small-movie/1999
$cq $a title download $movie --to $work/dl > /dev/null
cmp -s "$work/dl/$small" "$work/small/$small" || { echo "FAIL: title download"; exit 1; }
head -c 1000 "$work/small/$small" > "$work/dl/$small.part"; rm "$work/dl/$small"
$cq $a title download $movie --to $work/dl | grep -q "done$" || { echo "FAIL: download resumed"; exit 1; }
cmp -s "$work/dl/$small" "$work/small/$small" && [ ! -e "$work/dl/$small.part" ] || { echo "FAIL: download resumed whole"; exit 1; }
$cq $a title download $movie --to $work/dl | grep -q "already here$" || { echo "FAIL: download kept"; exit 1; }
kill $d_pid
echo PASS
