#!/bin/bash
# Build GhosttyVt.xcframework (libghostty-vt) from a ghostty checkout.
#
# The checkout must be ghostty as it is, without this package's patch series:
# those patches serve the embedded surface, and libghostty-vt has to match the
# terminal core termio's daemon builds (termio-sh/libghostty-rs).
#
# Upstream's universal build stops at arm64 for the iOS simulator, while
# GhosttyKit also carries x86_64 there, so that slice is built on its own and
# merged in. Then every global but the public API is made private
# (localize-vt-symbols.sh), so the library links beside GhosttyKit.
#
# usage: build-vt.sh <ghostty_source> <output_dir>
# writes <output_dir>/GhosttyVt.xcframework and GhosttyVt.xcframework.zip

set -euo pipefail

SOURCE=$(cd "${1:?usage: $0 <ghostty_source> <output_dir>}" && pwd)
mkdir -p "${2:?usage: $0 <ghostty_source> <output_dir>}"
OUT=$(cd "$2" && pwd)
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

(cd "$SOURCE" && zig build -Demit-lib-vt -Doptimize=ReleaseFast)
UPSTREAM="$SOURCE/zig-out/lib/ghostty-vt.xcframework"

library_of() {
    local identifier=$1 index=0
    while /usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index" "$UPSTREAM/Info.plist" >/dev/null 2>&1; do
        if [ "$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index:LibraryIdentifier" "$UPSTREAM/Info.plist")" = "$identifier" ]; then
            echo "$UPSTREAM/$identifier/$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index:LibraryPath" "$UPSTREAM/Info.plist")"
            return
        fi
        index=$((index + 1))
    done
    echo "[!] $identifier is not in $UPSTREAM" >&2
    exit 1
}

MACOS=$(library_of macos-arm64_x86_64)
IOS=$(library_of ios-arm64)
SIMULATOR_ARM=$(library_of ios-arm64-simulator)

(cd "$SOURCE" && zig build -Demit-lib-vt -Doptimize=ReleaseFast -Dtarget=x86_64-ios-simulator --prefix "$WORK/x86_64-simulator")
# The same libSystem override upstream applies to the slices it combines.
"$SOURCE/src/build/libsystem_override.sh" "$WORK/x86_64-simulator/lib/libghostty-vt.a" "$WORK/x86_64-simulator.a"

for slice in macos ios simulator; do mkdir -p "$WORK/$slice"; done
cp "$MACOS" "$WORK/macos/libghostty-vt.a"
cp "$IOS" "$WORK/ios/libghostty-vt.a"
lipo -create "$SIMULATOR_ARM" "$WORK/x86_64-simulator.a" -output "$WORK/simulator/libghostty-vt.a"

rm -rf "$OUT/GhosttyVt.xcframework" "$OUT/GhosttyVt.xcframework.zip"
xcodebuild -create-xcframework \
    -library "$WORK/macos/libghostty-vt.a" -headers "$UPSTREAM/macos-arm64_x86_64/Headers" \
    -library "$WORK/ios/libghostty-vt.a" -headers "$UPSTREAM/ios-arm64/Headers" \
    -library "$WORK/simulator/libghostty-vt.a" -headers "$UPSTREAM/ios-arm64-simulator/Headers" \
    -output "$OUT/GhosttyVt.xcframework"

"$SCRIPTS/localize-vt-symbols.sh" "$OUT/GhosttyVt.xcframework"
(cd "$OUT" && ditto -c -k --keepParent GhosttyVt.xcframework GhosttyVt.xcframework.zip)
echo "[*] $OUT/GhosttyVt.xcframework"
