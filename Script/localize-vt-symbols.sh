#!/bin/bash
# Make every global symbol in GhosttyVt.xcframework private except its C API.
#
# Zig bundles its UBSan and compiler runtimes into each static library it
# builds, as strong globals in the library's one compilation-unit object, and
# the libraries carry their C/C++ dependencies (simdutf, highway, …) the same
# way. libghostty and libghostty-vt are linked into one app, so a debug link —
# no -dead_strip — fails with duplicate ___ubsan_handle_* symbols. ghostty's
# own build says as much (src/build/GhosttyLibVt.zig: "This could cause
# problems if you're linking multiple static Zig libraries").
#
# Relinking each slice with `ld -r` and an exported-symbols list of `_ghostty_*`
# keeps the API and turns everything else into private externs, so each
# library keeps its own runtime and neither needs the other.
#
# usage: localize-vt-symbols.sh <GhosttyVt.xcframework>

set -euo pipefail

XCFRAMEWORK=${1:?usage: $0 <GhosttyVt.xcframework>}
PLIST="$XCFRAMEWORK/Info.plist"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
echo '_ghostty_*' > "$WORK/exports.txt"

index=0
while /usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index" "$PLIST" >/dev/null 2>&1; do
    entry=":AvailableLibraries:$index"
    identifier=$(/usr/libexec/PlistBuddy -c "Print $entry:LibraryIdentifier" "$PLIST")
    library=$(/usr/libexec/PlistBuddy -c "Print $entry:LibraryPath" "$PLIST")
    platform=$(/usr/libexec/PlistBuddy -c "Print $entry:SupportedPlatform" "$PLIST")
    variant=$(/usr/libexec/PlistBuddy -c "Print $entry:SupportedPlatformVariant" "$PLIST" 2>/dev/null || true)
    case "$platform${variant:+-$variant}" in
        macos) ld_platform=macos; minimum=13.0 ;;
        ios) ld_platform=ios; minimum=15.0 ;;
        ios-simulator) ld_platform=ios-simulator; minimum=15.0 ;;
        *) echo "[!] $identifier: unsupported platform $platform${variant:+ $variant}"; exit 1 ;;
    esac

    archive="$XCFRAMEWORK/$identifier/$library"
    slice="$WORK/$identifier"
    mkdir -p "$slice"
    thinned=()
    for arch in $(lipo -archs "$archive"); do
        if [ "$(lipo -archs "$archive" | wc -w)" -gt 1 ]; then
            lipo -thin "$arch" "$archive" -output "$slice/$arch.a"
        else
            cp "$archive" "$slice/$arch.a"
        fi
        ld -r -arch "$arch" -platform_version "$ld_platform" "$minimum" "$minimum" \
            -o "$slice/$arch.o" -force_load "$slice/$arch.a" \
            -exported_symbols_list "$WORK/exports.txt"
        ar rcs "$slice/$arch-localized.a" "$slice/$arch.o"
        others=$(nm -gU "$slice/$arch.o" | grep -vc ' _ghostty_' || true)
        exported=$(nm -gU "$slice/$arch.o" | grep -c ' _ghostty_' || true)
        if [ "$others" -ne 0 ] || [ "$exported" -eq 0 ]; then
            echo "[!] $identifier $arch: $exported API symbols, $others other globals"
            exit 1
        fi
        echo "[*] $identifier $arch: $exported API symbols exported, all else private"
        thinned+=("$slice/$arch-localized.a")
    done
    if [ "${#thinned[@]}" -gt 1 ]; then
        lipo -create "${thinned[@]}" -output "$archive"
    else
        cp "${thinned[0]}" "$archive"
    fi
    index=$((index + 1))
done

[ "$index" -gt 0 ] || { echo "[!] no libraries in $PLIST"; exit 1; }
