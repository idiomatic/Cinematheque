#!/bin/zsh
# Takes the README's screenshots of the apps, on the mock library
# (mock-library.sh), in dark and light appearance, into docs/screenshots:
# the Mac in a terrarium VM, the Apple TV and the iPhone in their
# simulators, and the web client by WebKit; with the Mac's and the Apple
# TV's, the hero. With names (mac, tv, iphone, web), only those; `video`,
# not among them unless named, also records the loop. See README.md.
set -eu
here=${0:A:h}
root=${here:h}
out=$root/docs/screenshots
terrarium=${TERRARIUM:-terrarium}
# The mock library's own port, apart from the 8642 a developer may serve
# it on (README.md), the web client's, and the video's Mac device's.
port=8649
web_port=8650
video_port=8651
which=($@)
(( $# )) || which=(mac tv iphone web)
for w in $which; do
    [[ $w == (mac|tv|iphone|web|video) ]] || { echo "usage: $0 [mac] [tv] [iphone] [web] [video]" >&2; exit 2 }
done
appearances=(dark light)
bundle=com.rbrian.cinematheque
# What each shows: the Mac's Series shelf, its band open on a season
# partway through, in the inspector; the Apple TV's page of that season,
# opened by its Top Shelf link, as a person's press opens it (Play focused
# first; pushed by CINEMATHEQUE_SELECT at launch, focus went to Start
# Over); the iPhone's Home, Series, and that season's page, side by side;
# the web client's Movies, wide.
season='t/s/the-rise-and-fall-of-sanctuary-moon/-#2'

tmp=$(mktemp -d)
pids=()
vm=
cleanup() {
    (( ${#pids} )) && kill $pids 2> /dev/null || true
    pids=()
    [[ -z $vm ]] || $terrarium stop $vm > /dev/null 2>&1 || true
    vm=
    rm -rf -- $tmp
}
# On a failure too: zsh skips the EXIT trap when `set -e` stops it within
# a function.
trap cleanup EXIT
trap 'cleanup; exit 1' ZERR
mkdir -p $out

cq=$root/cli/zig-out/bin/cinematheque
(cd $root/cli && zig build)
zsh $here/mock-library.sh --port $port --data $tmp/data $tmp/media > /dev/null
$cq --data $tmp/serve library create > /dev/null
$cq --data $tmp/serve serve --port $port --media $tmp/media > $tmp/serve.log 2>&1 &
pids+=($!)

# A tool of tools/screenshots/, built once.
tool() {
    [[ -x $tmp/$1 ]] || swiftc -O $here/screenshots/$1.swift -o $tmp/$1 ${@:2}
}

# Builds the app, Debug, as its launch options are debug builds' alone.
build() {
    xcodebuild -project $root/apple/Cinematheque.xcodeproj -scheme Cinematheque -configuration Debug \
        -destination $1 -derivedDataPath $tmp/dd build -quiet
}

# Squeezes a PNG: to a palette by pngquant (a quarter the bytes, alike at
# a README's sizes), then losslessly by oxipng, each if there is one.
squeeze() {
    if whence pngquant > /dev/null; then pngquant --quality 70-95 --speed 1 --strip --skip-if-larger --force --output $1 $1 || true; fi
    if whence oxipng > /dev/null; then oxipng -q -o 4 --strip safe $1; fi
}

# Waits for the screen to hold still: `$1 FILE` takes a shot into FILE,
# and three alike in a row, half a second apart, is still (covers have
# loaded), giving up after a minute.
settle() {
    local take=$1 dest=$2 same=0 i
    ${=take} $tmp/prev.png
    for i in {1..120}; do
        sleep 0.5
        ${=take} $tmp/next.png
        if cmp -s $tmp/prev.png $tmp/next.png; then
            (( ++same < 2 )) || { mv $tmp/next.png $dest; return }
        else
            same=0
        fi
        mv $tmp/next.png $tmp/prev.png
    done
    echo "error: the screen didn't settle" >&2
    exit 1
}

# A simulator's screenshot, quietly.
simshot() {
    xcrun simctl io $1 screenshot $2 > /dev/null 2>&1
}

# A simulator's UDID by its name, the newest runtime's.
udid() {
    xcrun simctl list devices available | grep -F "    $1 (" | tail -1 | grep -oE '[0-9A-F-]{36}'
}

# Readies a simulator by name for screens (`screen`), the app built and
# installed, its UDID in `id`.
simulator() {
    local name=$1 platform=$2 product=$3
    id=$(udid $name)
    [[ -n $id ]] || { echo "error: no $name simulator: add one in Xcode" >&2; exit 1 }
    build "id=$id"
    xcrun simctl boot $id 2> /dev/null || true
    xcrun simctl bootstatus $id > /dev/null
    [[ $platform == tvOS ]] || xcrun simctl status_bar $id override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
    xcrun simctl install $id $tmp/dd/Build/Products/Debug-$product/Cinematheque.app
}

# A screen of the app in `id`'s simulator: `screen APPEARANCE OUT [URL]
# [NAME=VALUE...]`, launched on a fresh copy of the data with those launch
# options, opening URL (if not empty) once it's launched.
screen() {
    local a=$1 shot=$2 link=$3
    shift 3
    xcrun simctl terminate $id $bundle 2> /dev/null || true
    rm -rf $tmp/run && cp -R $tmp/data $tmp/run
    env SIMCTL_CHILD_CINEMATHEQUE_DATA=$tmp/run SIMCTL_CHILD_CINEMATHEQUE_APPEARANCE=$a ${@/#/SIMCTL_CHILD_} xcrun simctl launch $id $bundle > /dev/null
    [[ -z $link ]] || xcrun simctl openurl $id $link
    settle "simshot $id" $shot
    xcrun simctl terminate $id $bundle
}

# The iPhone's three screens side by side (Home, the Series tab, and that
# season's page), as one tall screen alone stood far taller than the
# others in a row; each with the iPhone 17's rounded corners (55 points,
# at 3×), as a screenshot of one has none. Its appearance system-wide, the
# status bar's too.
if (( ${which[(Ie)iphone]} )); then
    tool side
    simulator "Mockup iPhone 17" iOS iphonesimulator
    for a in $appearances; do
        xcrun simctl ui $id appearance $a
        screen $a $tmp/home.png ""
        screen $a $tmp/series.png "" CINEMATHEQUE_TAB=series
        screen $a $tmp/season.png "" CINEMATHEQUE_TAB=home CINEMATHEQUE_SELECT=$season
        $tmp/side $out/iphone-$a.png 60 165 $tmp/home.png $tmp/series.png $tmp/season.png
        squeeze $out/iphone-$a.png
    done
    xcrun simctl status_bar $id clear 2> /dev/null || true
fi
# The Apple TV's appearance the app's alone, as its simulator's can't be
# set; at 1080p, as its 4K shot is four times the bytes.
if (( ${which[(Ie)tv]} )); then
    simulator "Mockup Apple TV 4K" tvOS appletvsimulator
    for a in $appearances; do
        screen $a $out/tv-$a.png "cinematheque://title?tile=${season/\#/%23}"
        sips -Z 1920 $out/tv-$a.png > /dev/null
        squeeze $out/tv-$a.png
        # Home, for the hero.
        screen $a $tmp/tv-home-$a.png ""
        sips -Z 1920 $tmp/tv-home-$a.png > /dev/null
    done
fi

if (( ${which[(Ie)web]} )); then
    tool web
    cp -R $tmp/data $tmp/web-data
    $cq --data $tmp/web-data serve --port $web_port > $tmp/web.log 2>&1 &
    pids+=($!)
    sleep 1
    for a in $appearances; do
        $tmp/web "http://127.0.0.1:$web_port/#movies" 960x720 $a $out/web-$a.png
        squeeze $out/web-$a.png
    done
fi

# The Mac's VM, for its shots and the video: started once, the app and
# the mock library in it, the library's media served as on the host.
guest() { $terrarium exec $vm -- /bin/zsh -c $1 }
shoot() { $terrarium shot $vm > $1 }
mac_vm() {
    [[ -z $vm ]] || return 0
    tool frame
    tool windows -target arm64-apple-macos14
    build 'platform=macOS,arch=arm64'
    (cd $tmp/dd/Build/Products/Debug && ditto -c -k --keepParent Cinematheque.app $tmp/app.zip)
    tar -czf $tmp/mock.tgz -C $tmp media data
    # 4 GB, as more pushes the host into swap; Retina, 1440×900 points.
    vm=$($terrarium start macos-27.2-quiet --ephemeral --memory 4096 --retina --by screenshots)
    $terrarium wait $vm > /dev/null
    $terrarium resize $vm 2880x1800 > /dev/null 2>&1 || true
    for f in app.zip mock.tgz windows; do $terrarium put $vm $tmp/$f /tmp/$f > /dev/null; done
    $terrarium put $vm $cq /tmp/cinematheque > /dev/null
    guest "cd /tmp && ditto -x -k app.zip /Applications && mkdir m && tar -xzf mock.tgz -C m && chmod +x cinematheque windows
        ./cinematheque --data /tmp/serve library create > /dev/null
        (nohup ./cinematheque --data /tmp/serve serve --port $port --media /tmp/m/media > /tmp/serve.log 2>&1 &)"
    # The shot's pixels a point.
    shoot $tmp/mac.png
    guest /tmp/windows > $tmp/windows.txt
    screen=(${=$(awk -F'\t' '$1 == "screen" {print $2}' $tmp/windows.txt)})
    scale=$(( $(sips -g pixelWidth $tmp/mac.png | awk '/pixelWidth/ {print $2}') / screen[1] ))
}
# Launches the app on a fresh copy of the guest's data directory DATA (in
# /tmp/m), its windows' places forgotten, with `open`'s options (`--env
# NAME=VALUE`).
launch() {
    local data=$1
    shift
    guest "pkill -x Cinematheque; sleep 1; D=~/Library/Application\ Support/Cinematheque; rm -rf \$D; mkdir -p \${D:h}; cp -R /tmp/m/$data \$D
        defaults delete $bundle 2> /dev/null; rm -rf ~/Library/Saved\ Application\ State/$bundle.savedState
        open ${(j: :)${(q)@}} -a /Applications/Cinematheque.app"
}
# Its window's bounds, once it's there, in `win`.
window() {
    win=
    for i in {1..60}; do
        guest /tmp/windows > $tmp/windows.txt
        win=$(awk -F'\t' '$2 == "Cinematheque" && $3 == 0 {print $4; exit}' $tmp/windows.txt)
        [[ -z $win ]] || return 0
        sleep 1
    done
    echo "error: the Mac app's window didn't appear" >&2
    exit 1
}
# Sizes the window as a person would, as SwiftUI sizes it again after the
# app could: dragged by its toolbar's empty right end to X,Y, then by its
# corner to W×H: `place X Y W H`, in points.
place() {
    window
    b=(${=win})
    $terrarium click $vm $(( (b[1] + b[3] - 200) * scale )),$(( (b[2] + 25) * scale )) --drag-to $(( ($1 + b[3] - 200) * scale )),$(( ($2 + 25) * scale )) --duration 600 > /dev/null
    window
    b=(${=win})
    $terrarium click $vm $(( (b[1] + b[3] - 1) * scale )),$(( (b[2] + b[4] - 1) * scale )) --drag-to $(( (b[1] + $3 - 1) * scale )),$(( (b[2] + $4 - 1) * scale )) --duration 600 > /dev/null
    window
    b=(${=win})
}
# Answers macOS's Local Network prompt if it's up, as it comes when it
# will in a launch, until a build has been allowed: Allow, at its foot's
# right, inside its shadow, until it's gone (a click as it slides in is
# lost). Whether it was up, in `asked`.
allow() {
    asked=
    for i in {1..30}; do
        guest /tmp/windows > $tmp/windows.txt
        prompt=$(awk -F'\t' '$2 == "UserNotificationCenter" {print $4}' $tmp/windows.txt)
        [[ -n $prompt ]] || return 0
        asked=1
        local p=(${=prompt})
        $terrarium click $vm $(( (p[1] + p[3] - 146) * scale )),$(( (p[2] + p[4] - 105) * scale )) > /dev/null
        sleep 1
    done
}
# The pointer off to the desktop's left, out of a shot, and off the Dock,
# whose names it shows.
park() { $terrarium move $vm $(( 20 * scale )),$(( 450 * scale )) > /dev/null }

if (( ${which[(Ie)mac]} )); then
    mac_vm
    for a in $appearances; do
        launch data --env CINEMATHEQUE_SELECT=$season --env CINEMATHEQUE_APPEARANCE=$a
        # At 80,124 (below the menu bar's notices), 1280×700 (above the
        # Dock).
        place 80 124 1280 700
        park
        # Shot again while the prompt was up when it was taken.
        for i in {1..5}; do
            allow
            settle shoot $tmp/mac.png
            allow
            [[ -n $asked ]] || break
        done
        window
        $tmp/frame $tmp/mac.png $out/mac-$a.png ${=win} 24 $scale
        squeeze $out/mac-$a.png
    done
fi

# The loop, in the README's How it works: a movie stopped partway on the
# Mac, then resumed on the Apple TV, which the Mac's change reached by
# syncing; driven at a person's pace, recorded, and made a silent animated
# WebP, each half fading in from black and out to it, in dark appearance.
if (( ${which[(Ie)video]} )); then
    movie=t/m/hold-the-corridor/2020
    # The Mac's device and the Apple TV's: the mock library's, and another
    # of its person's, paired by the command-line app and caught up.
    cp -R $tmp/data $tmp/va
    $cq --data $tmp/vb person pair > $tmp/pair.log 2>&1 &
    pids+=($!)
    for i in {1..100}; do grep -q '^listening' $tmp/pair.log && break; sleep 0.1; done
    $cq --data $tmp/va person pair $(grep -oE 'code [0-9]+' $tmp/pair.log | cut -d' ' -f2) \
        http://127.0.0.1:$(grep -oE 'port [0-9]+' $tmp/pair.log | cut -d' ' -f2)/pair > /dev/null
    $cq --data $tmp/va serve --port $video_port > $tmp/va.log 2>&1 &
    pids+=($!)
    sleep 1
    $cq --data $tmp/vb sync http://127.0.0.1:$video_port/ > /dev/null
    kill $pids[-1]

    # The Apple TV, on Home, and the port it serves on, for the Mac.
    simulator "Mockup Apple TV 4K" tvOS appletvsimulator
    xcrun simctl terminate $id $bundle 2> /dev/null || true
    tv=$(SIMCTL_CHILD_CINEMATHEQUE_DATA=$tmp/vb SIMCTL_CHILD_CINEMATHEQUE_APPEARANCE=dark xcrun simctl launch $id $bundle | awk '{print $NF}')
    tv_port=
    for i in {1..100}; do
        tv_port=$(lsof -nP -a -p $tv -iTCP -sTCP:LISTEN -Fn 2> /dev/null | awk -F: '/^n/ {print $NF; exit}')
        [[ -z $tv_port ]] || break
        sleep 0.2
    done
    [[ -n $tv_port ]] || { echo "error: the Apple TV app isn't serving" >&2; exit 1 }

    # The Mac, which reaches the Apple TV by the host's address on its
    # network, added, as DNS-SD doesn't cross the VM's NAT.
    mac_vm
    tar -czf $tmp/va.tgz -C $tmp va
    $terrarium put $vm $tmp/va.tgz /tmp/va.tgz > /dev/null
    host=$(guest "route -n get default | awk '/gateway/ {print \$2}'")
    guest "tar -xzf /tmp/va.tgz -C /tmp/m && /tmp/cinematheque --data /tmp/m/va device add http://$host:$tv_port/ > /dev/null"
    launch va --env CINEMATHEQUE_APPEARANCE=dark
    # 16:9, as the Apple TV's screen, above the Dock.
    place 96 110 1248 702
    park
    for i in {1..5}; do allow; settle shoot $tmp/mac.png; allow; [[ -n $asked ]] || break; done
    # Movies in the sidebar, then the movie's tile, first there, in points
    # from the window's corner; Return plays it, as double-clicking does
    # (the inspector's Play is below the window's foot, under the movie's
    # tall cover).
    at() { print -- $(( (b[1] + $1) * scale )),$(( (b[2] + $2) * scale )) }
    $terrarium record $vm $tmp/mac.mp4 --fps 30 --crop $(( b[1] * scale )),$(( b[2] * scale )),$(( b[3] * scale )),$(( b[4] * scale )) > /dev/null
    sleep 1
    $terrarium click $vm $(at 67 68) --duration 700 > /dev/null
    sleep 0.8
    $terrarium click $vm $(at 274 182) --duration 700 > /dev/null
    sleep 1.2
    $terrarium key $vm return > /dev/null
    sleep 3.5
    # Ahead 30 seconds, as a person skips past what they've seen, then
    # back to the library, the position saved and synced.
    for i in 1 2 3; do $terrarium key $vm right > /dev/null; sleep 0.5; done
    sleep 1
    $terrarium key $vm escape > /dev/null
    sleep 2
    $terrarium record $vm --stop > /dev/null

    # Once the Apple TV has it: Home, then the movie played as its Top
    # Shelf item plays it, resuming.
    for i in {1..150}; do
        $cq --data $tmp/vb progress list $movie 2> /dev/null | grep -q ' at ' && break
        sleep 0.2
    done
    xcrun simctl io $id recordVideo --codec=h264 --force $tmp/tv.mov > /dev/null 2>&1 &
    rec=$!
    sleep 2
    xcrun simctl openurl $id "cinematheque://title?tile=$movie&play=1"
    sleep 5.5
    kill -INT $rec
    wait $rec || true
    xcrun simctl terminate $id $bundle

    # Each half 1280×720 at 15 frames a second, fading in from black and
    # out to it (half a second, as the apps fade playing), one after the
    # other, then a looping WebP.
    clip() {
        local d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 $1)
        ffmpeg -v error -nostdin -y -i $1 -an -vf "scale=1280:720,fps=15,format=yuv420p,fade=t=in:d=0.5,fade=t=out:st=$(( d - 0.5 )):d=0.5" $2
    }
    clip $tmp/mac.mp4 $tmp/a.mp4
    clip $tmp/tv.mov $tmp/b.mp4
    mkdir $tmp/frames
    ffmpeg -v error -nostdin -y -i $tmp/a.mp4 -i $tmp/b.mp4 -filter_complex concat=n=2:v=1 $tmp/frames/%04d.png
    # At quality 85, as at lower qualities img2webp takes a fade's small
    # changes for none, leaving blocks of the frames before.
    img2webp -loop 0 -lossy -q 85 -d 67 $tmp/frames/*.png -o $out/loop.webp > /dev/null
fi

# The hero, at the README's top: the Mac's window, and in front of it, the
# Apple TV's Home, by hero.swift, once both are taken.
if (( ${which[(Ie)mac]} && ${which[(Ie)tv]} )); then
    tool hero
    for a in $appearances; do
        $tmp/hero $out/hero-$a.png $out/mac-$a.png $tmp/tv-home-$a.png
        squeeze $out/hero-$a.png
    done
fi

ls -l $out
