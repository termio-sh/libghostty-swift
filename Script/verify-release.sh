#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[*] malformed project structure"
    exit 1
fi

RELEASE_TAG=${1:-}
STORAGE_RELEASE_TAG=${2:-}

if [ -z "$RELEASE_TAG" ] || [ -z "$STORAGE_RELEASE_TAG" ]; then
    echo "Usage: $0 <release_tag> <storage_release_tag>"
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "[!] gh not found"
    exit 1
fi

git fetch --tags origin

release_commit=$(git rev-parse "refs/tags/$RELEASE_TAG")
storage_commit=$(git rev-parse "refs/tags/$STORAGE_RELEASE_TAG")

if [ "$release_commit" != "$storage_commit" ]; then
    echo "[!] release tag and storage tag point at different commits"
    echo "    $RELEASE_TAG: $release_commit"
    echo "    $STORAGE_RELEASE_TAG: $storage_commit"
    exit 1
fi

manifest=$(git show "$RELEASE_TAG:Package.swift")
repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

# Each binary target is checked by name: its URL must be this storage release's
# asset, and the asset's digest must be the target's checksum.
verify_target() {
    local target=$1 asset=$2
    local fields download_url checksum
    fields=$(printf '%s\n' "$manifest" | python3 -c '
import re, sys
text, name = sys.stdin.read(), sys.argv[1]
match = re.search(r"\.binaryTarget\(\s*name:\s*\"" + re.escape(name) + r"\",\s*url:\s*\"([^\"]+)\",\s*checksum:\s*\"([0-9a-f]{64})\"", text)
print(f"{match.group(1)} {match.group(2)}" if match else "", end="")
' "$target")
    download_url=${fields%% *}
    checksum=${fields##* }
    if [ -z "$fields" ]; then
        echo "[!] no binary target $target with a URL and checksum in Package.swift at $RELEASE_TAG"
        exit 1
    fi
    local expected_url="https://github.com/$repo/releases/download/$STORAGE_RELEASE_TAG/$asset"
    if [ "$download_url" != "$expected_url" ]; then
        echo "[!] $target download URL does not match the storage release"
        echo "    expected: $expected_url"
        echo "    actual:   $download_url"
        exit 1
    fi
    local asset_digest
    asset_digest=$(
        gh release view "$STORAGE_RELEASE_TAG" \
            --json assets \
            --jq ".assets[] | select(.name == \"$asset\") | .digest"
    )
    if [ -z "$asset_digest" ]; then
        echo "[!] release asset not found: $STORAGE_RELEASE_TAG/$asset"
        exit 1
    fi
    if [ "$asset_digest" != "sha256:$checksum" ]; then
        echo "[!] $asset digest does not match the $target checksum"
        echo "    asset:    $asset_digest"
        echo "    manifest: sha256:$checksum"
        exit 1
    fi
    echo "[*] release verified: $RELEASE_TAG $target -> $STORAGE_RELEASE_TAG/$asset"
}

verify_target libghostty GhosttyKit.xcframework.zip
verify_target GhosttyVt GhosttyVt.xcframework.zip
