#!/bin/zsh
# Builds the core's static library for each architecture Xcode is building,
# for the platform it's building for (macOS, tvOS, iOS, or their simulators), and
# combines them, since Zig builds one target at a time. Each is linked into
# one object exporting only the C interface (cq_*), so the compiler runtime
# Zig bundles stays private and can't clash with Xcode's.
set -eu
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
case $PLATFORM_NAME in
    macosx) os=macos; platform=macos; version=$MACOSX_DEPLOYMENT_TARGET; abi= ;;
    appletvos) os=tvos; platform=tvos; version=$TVOS_DEPLOYMENT_TARGET; abi= ;;
    appletvsimulator) os=tvos; platform=tvos-simulator; version=$TVOS_DEPLOYMENT_TARGET; abi=-simulator ;;
    iphoneos) os=ios; platform=ios; version=$IPHONEOS_DEPLOYMENT_TARGET; abi= ;;
    iphonesimulator) os=ios; platform=ios-simulator; version=$IPHONEOS_DEPLOYMENT_TARGET; abi=-simulator ;;
    *) print -u2 "error: no core for $PLATFORM_NAME"; exit 1 ;;
esac
# Release builds' core is ReleaseSafe, as releases' are; Debug builds' is
# Zig's Debug, unoptimized, as it builds several times faster.
case $CONFIGURATION in
    Debug) optimize=() ;;
    *) optimize=(--release=safe) ;;
esac
out="$DERIVED_FILE_DIR/core"
libs=()
cd "$SRCROOT/../core"
for arch in ${=ARCHS}; do
    case $arch in
        arm64) zig_arch=aarch64 ;;
        *) zig_arch=$arch ;;
    esac
    zig build $optimize -Dtarget=$zig_arch-$os.$version$abi --sysroot "$SDKROOT" --prefix "$out/$arch"
    xcrun ld -r -arch $arch -platform_version $platform $version $version -exported_symbol '_cq_*' -all_load "$out/$arch/lib/libcinematheque.a" -o "$out/$arch/core.o"
    rm -f "$out/$arch/libcore.a"
    xcrun libtool -static -o "$out/$arch/libcore.a" "$out/$arch/core.o"
    libs+=("$out/$arch/libcore.a")
done
mkdir -p "$out/lib"
lipo -create $libs -output "$out/lib/libcinematheque.a"
