#!/bin/zsh

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[-] malformed project structure"
    exit 1
fi

SOURCE_DIR=${1:-}
PATCH_DIR=${2:-"$(pwd)/Patches/ghostty"}

if [ -z "$SOURCE_DIR" ]; then
    echo "Usage: $0 <source_dir> [patch_dir]"
    exit 1
fi

if [ ! -d "$SOURCE_DIR" ]; then
    echo "[-] ghostty source directory not found: $SOURCE_DIR"
    exit 1
fi

if [ ! -d "$PATCH_DIR" ]; then
    echo "[+] no patches directory found: $PATCH_DIR"
    exit 0
fi

apply_unified_patch() {
    local patch_file="$1"

    # -e, not -d: a git worktree's .git is a file.
    if [ -e "$SOURCE_DIR/.git" ] && command -v git >/dev/null 2>&1; then
        if git -C "$SOURCE_DIR" apply --check --reverse "$patch_file" >/dev/null 2>&1; then
            echo "[+] patch already applied: $(basename "$patch_file")"
            return
        fi

        if ! git -C "$SOURCE_DIR" apply --check "$patch_file" >/dev/null 2>&1; then
            echo "[-] failed to validate patch: $patch_file"
            exit 1
        fi

        git -C "$SOURCE_DIR" apply "$patch_file"
        echo "[+] applied patch: $(basename "$patch_file")"
        return
    fi

    # -f: never let patch guess the direction. Without it a forward patch
    # that has not been applied can "succeed" as a reverse dry run.
    if patch -p1 -R -f --dry-run -d "$SOURCE_DIR" <"$patch_file" >/dev/null 2>&1; then
        echo "[+] patch already applied: $(basename "$patch_file")"
        return
    fi

    if ! patch -p1 -f --dry-run -d "$SOURCE_DIR" <"$patch_file" >/dev/null 2>&1; then
        echo "[-] failed to validate patch: $patch_file"
        exit 1
    fi

    patch -p1 -f -d "$SOURCE_DIR" <"$patch_file" >/dev/null
    echo "[+] applied patch: $(basename "$patch_file")"
}

# Series-level stamp.
#
# Per-patch reverse detection cannot answer "is this series already applied?"
# once patches overlap: 0002, 0004 and 0007 all edit src/apprt/embedded.zig, so
# reverse-applying 0002 alone no longer matches after the later two have run.
# `build-ghostty.sh` re-runs this script once per target against one source
# tree, which made every multi-target local build fail on the second target.
# CI never saw it because each target is a separate job with a fresh clone.
#
# So stamp the tree with a digest of the patch set. An identical set is a
# no-op; a changed set is a hard error, because this script cannot layer a
# new series on top of an already-patched tree.
STAMP_FILE="$SOURCE_DIR/.libghostty-patches-applied"
PATCH_SET_DIGEST="$(
    find "$PATCH_DIR" -type f ! -name '*.md' -print0 |
        sort -z |
        xargs -0 shasum -a 256 |
        awk '{print $1}' |
        shasum -a 256 |
        awk '{print $1}'
)"

if [ -f "$STAMP_FILE" ]; then
    PREVIOUS="$(cat "$STAMP_FILE")"
    if [ "$PREVIOUS" = "$PATCH_SET_DIGEST" ]; then
        echo "[+] patch series already applied (${PATCH_SET_DIGEST:0:12})"
        exit 0
    fi
    echo "[-] source tree carries a different patch series"
    echo "    applied: ${PREVIOUS:0:12}"
    echo "    wanted:  ${PATCH_SET_DIGEST:0:12}"
    echo "    start from a clean ghostty checkout"
    exit 1
fi

for patch_file in "$PATCH_DIR"/*; do
    [ -e "$patch_file" ] || continue

    case "$patch_file" in
        *.md) ;;
        *.patch)
            apply_unified_patch "$patch_file"
            ;;
        *.sh)
            "$patch_file" "$SOURCE_DIR"
            ;;
        *)
            echo "[-] unsupported patch file: $patch_file"
            exit 1
            ;;
    esac
done

# Only stamp once every patch in the series has succeeded.
printf '%s\n' "$PATCH_SET_DIGEST" > "$STAMP_FILE"
