#!/bin/zsh
# Takes the README's screenshots of the apps, on the mock library
# (mock-library.sh), in dark and light appearance, into docs/screenshots:
# the Mac in a terrarium VM, the Apple TV and the iPhone in their
# simulators, and the web client by WebKit. With names (mac, tv, iphone,
# web), only those. See README.md.
set -eu
here=${0:A:h}
root=${here:h}
out=$root/docs/screenshots
terrarium=${TERRARIUM:-terrarium}
# The mock library's own port, apart from the 8642 a developer may serve
# it on (README.md), and the web client's.
port=8649
web_port=8650
which=($@)
(( $# )) || which=(mac tv iphone web)
for w in $which; do
    [[ $w == (mac|tv|iphone|web) ]] || { echo "usage: $0 [mac] [tv] [iphone] [web]" >&2; exit 2 }
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
    simulator "iPhone 17" iOS iphonesimulator
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
    simulator "Apple TV 4K (3rd generation)" tvOS appletvsimulator
    for a in $appearances; do
        screen $a $out/tv-$a.png "cinematheque://title?tile=${season/\#/%23}"
        sips -Z 1920 $out/tv-$a.png > /dev/null
        squeeze $out/tv-$a.png
    done
fi

if (( ${which[(Ie)web]} )); then
    tool web
    cp -R $tmp/data $tmp/web-data
    $cq --data $tmp/web-data serve --port $web_port --web > $tmp/web.log 2>&1 &
    pids+=($!)
    sleep 1
    for a in $appearances; do
        $tmp/web "http://127.0.0.1:$web_port/#movies" 960x720 $a $out/web-$a.png
        squeeze $out/web-$a.png
    done
fi

if (( ${which[(Ie)mac]} )); then
    tool frame
    tool windows -target arm64-apple-macos14
    build 'platform=macOS,arch=arm64'
    (cd $tmp/dd/Build/Products/Debug && ditto -c -k --keepParent Cinematheque.app $tmp/app.zip)
    tar -czf $tmp/mock.tgz -C $tmp media data
    # 4 GB, as more pushes the host into swap.
    vm=$($terrarium start macos-27.2-quiet --ephemeral --memory 4096 --by screenshots)
    $terrarium wait $vm > /dev/null
    $terrarium resize $vm 1440x900 > /dev/null 2>&1 || true
    for f in app.zip mock.tgz windows; do $terrarium put $vm $tmp/$f /tmp/$f > /dev/null; done
    $terrarium put $vm $cq /tmp/cinematheque > /dev/null
    guest() { $terrarium exec $vm -- /bin/zsh -c $1 }
    guest "cd /tmp && ditto -x -k app.zip /Applications && mkdir m && tar -xzf mock.tgz -C m && chmod +x cinematheque windows
        ./cinematheque --data /tmp/serve library create > /dev/null
        (nohup ./cinematheque --data /tmp/serve serve --port $port --media /tmp/m/media > /tmp/serve.log 2>&1 &)"
    shoot() { $terrarium shot $vm > $1 }
    # The shot's pixels a point.
    shoot $tmp/mac.png
    guest /tmp/windows > $tmp/windows.txt
    screen=(${=$(awk -F'\t' '$1 == "screen" {print $2}' $tmp/windows.txt)})
    scale=$(( $(sips -g pixelWidth $tmp/mac.png | awk '/pixelWidth/ {print $2}') / screen[1] ))
    # Launches the app on a fresh copy of the data, its windows' places
    # forgotten, with `open`'s options (`--env NAME=VALUE`).
    launch() {
        guest "pkill -x Cinematheque; sleep 1; D=~/Library/Application\ Support/Cinematheque; rm -rf \$D; mkdir -p \${D:h}; cp -R /tmp/m/data \$D
            defaults delete $bundle 2> /dev/null; rm -rf ~/Library/Saved\ Application\ State/$bundle.savedState
            open ${(j: :)${(q)@}} -a /Applications/Cinematheque.app"
    }
    # Its window's bounds, once it's there.
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
    # Answers macOS's Local Network prompt if it's up, as it comes when
    # it will in a launch, until a build has been allowed: Allow, at its
    # foot's right, inside its shadow, until it's gone (a click as it
    # slides in is lost). Whether it was up, in `asked`.
    allow() {
        asked=
        for i in {1..30}; do
            guest /tmp/windows > $tmp/windows.txt
            prompt=$(awk -F'\t' '$2 == "UserNotificationCenter" {print $4}' $tmp/windows.txt)
            [[ -n $prompt ]] || return 0
            asked=1
            b=(${=prompt})
            $terrarium click $vm $(( (b[1] + b[3] - 146) * scale )),$(( (b[2] + b[4] - 105) * scale )) > /dev/null
            sleep 1
        done
    }
    for a in $appearances; do
        launch --env CINEMATHEQUE_SELECT=$season --env CINEMATHEQUE_APPEARANCE=$a
        window
        # Sized as a person would size it, as SwiftUI sizes it again after
        # the app could: dragged by its toolbar's empty right end to
        # 80,124 (below the menu bar's notices), then by its corner to
        # 1280×700 (above the Dock).
        b=(${=win})
        $terrarium click $vm $(( (b[1] + b[3] - 200) * scale )),$(( (b[2] + 25) * scale )) --drag-to $(( (80 + b[3] - 200) * scale )),$(( (124 + 25) * scale )) --duration 600 > /dev/null
        window
        b=(${=win})
        $terrarium click $vm $(( (b[1] + b[3] - 1) * scale )),$(( (b[2] + b[4] - 1) * scale )) --drag-to $(( (b[1] + 1280 - 1) * scale )),$(( (b[2] + 700 - 1) * scale )) --duration 600 > /dev/null
        # The pointer off to the desktop's left, out of the shot, and off
        # the Dock, whose names it shows.
        $terrarium move $vm $(( 20 * scale )),$(( 450 * scale )) > /dev/null
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

ls -l $out
