#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"
METAL_ZIG="$SOURCE_DIR/src/renderer/Metal.zig"
DEVICE_ZIG="$SOURCE_DIR/src/renderer/metal/Device.zig"

if [ ! -f "$METAL_ZIG" ]; then
    echo "[-] Metal.zig not found"
    exit 1
fi

# Upstream moved the device metadata out of Metal.zig into its own Device.zig
# (ghostty 35a81a9, "renderer: metal device context"). The storage mode now
# lives there and Metal.zig reads it through `self.device`.
if [ ! -f "$DEVICE_ZIG" ]; then
    echo "[-] renderer/metal/Device.zig not found"
    exit 1
fi

if grep -q 'LIBGHOSTTY_SPM_TEXTURE_STORAGE_PATCH' "$DEVICE_ZIG"; then
    echo "[+] Metal texture storage already patched"
    exit 0
fi

python3 - "$DEVICE_ZIG" "$METAL_ZIG" <<'PY'
import sys
from pathlib import Path

device_path = Path(sys.argv[1])
metal_path = Path(sys.argv[2])

for path in (device_path, metal_path):
    if not path.is_file():
        print(f"[-] missing file: {path}")
        sys.exit(1)

device_src = device_path.read_text()
metal_src = metal_path.read_text()


def require(condition, message):
    """Explicit check. Never use `assert` — `python -O` strips it."""
    if not condition:
        print(f"[-] {message}")
        sys.exit(1)


def replace_exact(text, old, new, what, expected=1):
    found = text.count(old)
    if found != expected:
        print(f"[-] {what}: expected {expected} match(es), found {found}")
        print(f"    {old[:80]}...")
        sys.exit(1)
    return text.replace(old, new, expected)


# ──────────────────────────────────────────────────────────────────────
# 1. Add the texture storage mode field, derive it, and populate it.
# ──────────────────────────────────────────────────────────────────────
device_src = replace_exact(
    device_src,
    """default_storage_mode: mtl.MTLResourceOptions.StorageMode,

/// The maximum 2D texture width and height supported by the device.
""",
    """default_storage_mode: mtl.MTLResourceOptions.StorageMode,

/// The default storage mode to use for MTLTexture resources.
default_texture_storage_mode: mtl.MTLResourceOptions.StorageMode,

/// The maximum 2D texture width and height supported by the device.
""",
    "Device.zig storage mode field",
)

device_src = replace_exact(
    device_src,
    """    const max_texture_size = queryMaxTextureSize(device);
    log.debug(
        "device properties default_storage_mode={} max_texture_size={}",
        .{ default_storage_mode, max_texture_size },
    );
""",
    """    // LIBGHOSTTY_SPM_TEXTURE_STORAGE_PATCH
    // MTLStorageModeShared is valid for textures on Apple GPUs, while Intel
    // and AMD macOS GPUs require managed textures even when hasUnifiedMemory is
    // true. Keep buffer storage unchanged, but choose texture storage from the
    // Metal GPU family as Apple recommends for CPU-updated textures.
    const default_texture_storage_mode: mtl.MTLResourceOptions.StorageMode = switch (comptime builtin.os.tag) {
        .ios => .shared,
        .macos => if (device.msgSend(
            bool,
            objc.sel("supportsFamily:"),
            .{mtl.MTLGPUFamily.apple1},
        )) .shared else .managed,
        else => default_storage_mode,
    };
    const max_texture_size = queryMaxTextureSize(device);
    log.debug(
        "device properties default_storage_mode={} default_texture_storage_mode={} max_texture_size={}",
        .{ default_storage_mode, default_texture_storage_mode, max_texture_size },
    );
""",
    "Device.zig device properties block",
)

device_src = replace_exact(
    device_src,
    """        .default_storage_mode = default_storage_mode,
        .max_texture_size = max_texture_size,
""",
    """        .default_storage_mode = default_storage_mode,
        .default_texture_storage_mode = default_texture_storage_mode,
        .max_texture_size = max_texture_size,
""",
    "Device.zig struct initializer",
)

# ──────────────────────────────────────────────────────────────────────
# 2. Retarget the texture call sites — and only those.
#
# This used to replace *every* `.storage_mode = self.default_storage_mode`
# after merely asserting there were at least four, then walk the buffer one
# back. A fifth, non-texture use added upstream would have been silently
# rewritten. Each texture site is now pinned by its own surrounding context and
# must match exactly once; `bufferOptions` is never touched at all.
# ──────────────────────────────────────────────────────────────────────
texture_sites = [
    # The render target texture in initTarget.
    (
        "        .storage_mode = self.device.default_storage_mode,\n"
        "        .width = width,\n"
        "        .height = height,\n",
        "        .storage_mode = self.device.default_texture_storage_mode,\n"
        "        .width = width,\n"
        "        .height = height,\n",
        "Metal.zig target texture",
    ),
    # textureOptions — custom shader textures.
    (
        "            .storage_mode = self.device.default_storage_mode,\n"
        "        },\n"
        "        .usage = .{\n"
        "            // textureOptions is currently only used for custom shaders,\n",
        "            .storage_mode = self.device.default_texture_storage_mode,\n"
        "        },\n"
        "        .usage = .{\n"
        "            // textureOptions is currently only used for custom shaders,\n",
        "Metal.zig textureOptions",
    ),
    # The shader-read-only image texture options.
    (
        "            .storage_mode = self.device.default_storage_mode,\n"
        "        },\n"
        "        .usage = .{\n"
        "            // We only need to read from this texture from a shader.\n",
        "            .storage_mode = self.device.default_texture_storage_mode,\n"
        "        },\n"
        "        .usage = .{\n"
        "            // We only need to read from this texture from a shader.\n",
        "Metal.zig image texture options",
    ),
    # initAtlasTexture — nested one level deeper, hence the wider indent.
    (
        "                .storage_mode = self.device.default_storage_mode,\n"
        "            },\n"
        "            .usage = .{\n"
        "                // We only need to read from this texture from a shader.\n",
        "                .storage_mode = self.device.default_texture_storage_mode,\n"
        "            },\n"
        "            .usage = .{\n"
        "                // We only need to read from this texture from a shader.\n",
        "Metal.zig atlas texture",
    ),
]

for old, new, what in texture_sites:
    metal_src = replace_exact(metal_src, old, new, what)

# ──────────────────────────────────────────────────────────────────────
# Postconditions: exactly the four texture sites moved, and the buffer path
# still reads the untouched buffer storage mode.
# ──────────────────────────────────────────────────────────────────────
require(
    metal_src.count(".storage_mode = self.device.default_texture_storage_mode") == 4,
    "postcondition: expected exactly 4 texture storage call sites, found "
    f"{metal_src.count('.storage_mode = self.device.default_texture_storage_mode')}",
)

buffer_marker = "pub inline fn bufferOptions(self: Metal) bufferpkg.Options {"
buffer_start = metal_src.find(buffer_marker)
require(buffer_start != -1, "postcondition: bufferOptions not found")
buffer_end = metal_src.find("\n}\n", buffer_start)
require(buffer_end != -1, "postcondition: bufferOptions has no closing brace")
buffer_body = metal_src[buffer_start:buffer_end]
require(
    ".storage_mode = self.device.default_storage_mode," in buffer_body,
    "postcondition: bufferOptions no longer uses the buffer storage mode",
)
require(
    "LIBGHOSTTY_SPM_TEXTURE_STORAGE_PATCH" in device_src,
    "postcondition: marker missing from Device.zig",
)

# All transformations succeeded — commit both files together, so a failure
# above can never leave the tree half-patched.
device_path.write_text(device_src)
metal_path.write_text(metal_src)
print("[+] patched Device.zig/Metal.zig: split buffer and texture storage modes")
PY
