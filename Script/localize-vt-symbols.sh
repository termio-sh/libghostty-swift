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
# Relinking each slice with `ld -r` and an exported-symbols list of the public
# API — every function its headers declare with GHOSTTY_API — keeps that API
# and turns everything else into private externs, internal `ghostty_*`
# helpers included (the SIMD ones are global too), so each library keeps its
# own runtime and neither needs the other.
#
# usage: localize-vt-symbols.sh <GhosttyVt.xcframework>

set -euo pipefail

XCFRAMEWORK=${1:?usage: $0 <GhosttyVt.xcframework>}
PLIST="$XCFRAMEWORK/Info.plist"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

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
    headers="$XCFRAMEWORK/$identifier/Headers"
    python3 - "$headers" > "$slice/exports.txt" <<'PY'
import pathlib, re, sys
names = set()
for header in pathlib.Path(sys.argv[1]).rglob("*.h"):
    # wasm.h declares the allocator hooks only a WebAssembly build defines.
    if header.name == "wasm.h":
        continue
    text = re.sub(r"/\*.*?\*/", " ", header.read_text(), flags=re.S)
    for declaration in re.findall(r"GHOSTTY_API\b[^;{]*?\b(ghostty_\w+)\s*\(", text):
        names.add(declaration)
for name in sorted(names):
    print("_" + name)
PY
    api=$(wc -l < "$slice/exports.txt" | tr -d ' ')
    [ "$api" -gt 0 ] || { echo "[!] $identifier: no GHOSTTY_API declarations in $headers"; exit 1; }
    thinned=()
    for arch in $(lipo -archs "$archive"); do
        if [ "$(lipo -archs "$archive" | wc -w)" -gt 1 ]; then
            lipo -thin "$arch" "$archive" -output "$slice/$arch.a"
        else
            cp "$archive" "$slice/$arch.a"
        fi
        ld -r -arch "$arch" -platform_version "$ld_platform" "$minimum" "$minimum" \
            -o "$slice/$arch.o" -force_load "$slice/$arch.a" \
            -exported_symbols_list "$slice/exports.txt"
        ar rcs "$slice/$arch-localized.a" "$slice/$arch.o"
        nm -gU "$slice/$arch.o" | awk '{print $3}' | sort > "$slice/$arch.exported"
        sort "$slice/exports.txt" > "$slice/declared.sorted"
        extra=$(comm -23 "$slice/$arch.exported" "$slice/declared.sorted" | wc -l | tr -d ' ')
        missing=$(comm -13 "$slice/$arch.exported" "$slice/declared.sorted" | wc -l | tr -d ' ')
        if [ "$extra" -ne 0 ] || [ "$missing" -ne 0 ]; then
            echo "[!] $identifier $arch: $extra globals beyond the API, $missing API functions not exported"
            comm -3 "$slice/$arch.exported" "$slice/declared.sorted" | head -20
            exit 1
        fi
        echo "[*] $identifier $arch: exactly the $api API functions are global"
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
