#!/bin/bash

# Never draw into an IOSurface the compositor may still be reading.
#
# The Metal renderer's swap chain frees a frame's target when the *GPU* has
# finished it, and presents by handing the surface to the main queue as a
# block. Nothing ties the two together: with three targets the renderer
# re-uses a surface two frames after dispatching its present, and if the
# main thread has not run that block yet — a host busy re-rendering its own
# UI, which is the normal state of an embedder under a burst of output — the
# layer is still showing that surface while the next frame is drawn into it.
# The compositor scans out a half-written frame; on Apple's tile-based GPUs
# the boundary is a clean vertical stripe, so a pane shows one scroll state
# on the left and another on the right until the next present lands.
#
# The layer's present callback now records what is on screen and how many
# presents are queued, and the renderer skips a draw while any present is
# pending or while the next target is the one on screen, keeping its dirty
# state so the following tick draws. Under a prompt main thread nothing
# changes; under a late one frames coalesce instead of tearing.
#
# Anchored on the text 0005-ios-metal-rendering leaves behind (its iOS
# present branch), so it must run after it.

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"
LAYER_ZIG="$SOURCE_DIR/src/renderer/metal/IOSurfaceLayer.zig"
METAL_ZIG="$SOURCE_DIR/src/renderer/Metal.zig"
GENERIC_ZIG="$SOURCE_DIR/src/renderer/generic.zig"

for f in "$LAYER_ZIG" "$METAL_ZIG" "$GENERIC_ZIG"; do
    if [ ! -f "$f" ]; then
        echo "[-] not found: $f"
        exit 1
    fi
done

if grep -q 'LIBGHOSTTY_SPM_PRESENT_BACKPRESSURE_PATCH' "$GENERIC_ZIG"; then
    echo "[+] present backpressure already patched"
    exit 0
fi

python3 - "$LAYER_ZIG" "$METAL_ZIG" "$GENERIC_ZIG" <<'PY'
import sys
from pathlib import Path

layer_path, metal_path, generic_path = (Path(p) for p in sys.argv[1:4])

MARKER = "LIBGHOSTTY_SPM_PRESENT_BACKPRESSURE_PATCH"


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


# Staged: nothing is written until every file transformed cleanly.
pending = []

# ──────────────────────────────────────────────────────────────────────
# 1. IOSurfaceLayer.zig — the present state, and the callback that keeps it.
# ──────────────────────────────────────────────────────────────────────
layer = layer_path.read_text()

layer = replace_exact(
    layer,
    """/// The underlying CALayer
layer: objc.Object,
""",
    f"""/// The underlying CALayer
layer: objc.Object,

/// {MARKER}
/// What the compositor holds of ours, shared between the main thread (which
/// moves the layer's contents) and the renderer thread (which must not draw
/// into a surface until the layer has moved off it).
pub const PresentState = struct {{
    /// Presents handed to the main queue that have not run yet.
    pending: std.atomic.Value(u32) = .{{ .raw = 0 }},
    /// The surface currently assigned as the layer's contents, by address.
    /// Zero before the first present.
    displayed: std.atomic.Value(usize) = .{{ .raw = 0 }},
}};
""",
    "IOSurfaceLayer.zig present state",
)

layer = replace_exact(
    layer,
    """pub inline fn setSurface(self: *IOSurfaceLayer, surface: *IOSurface) !void {
    // We retain the surface to make sure it's not GC'd
    // before we can set it as the contents of the layer.
    //
    // We release in the callback after setting the contents.
    surface.retain();
    // NOTE: Since `self.layer` is passed as an `objc.c.id`, it's
    //       automatically retained when the block is copied, so we
    //       don't need to retain it ourselves like with the surface.

    var block = SetSurfaceBlock.init(.{
        .layer = self.layer.value,
        .surface = surface,
    }, &setSurfaceCallback);
""",
    """pub inline fn setSurface(
    self: *IOSurfaceLayer,
    surface: *IOSurface,
    state: *PresentState,
) !void {
    // We retain the surface to make sure it's not GC'd
    // before we can set it as the contents of the layer.
    //
    // We release in the callback after setting the contents.
    surface.retain();
    // NOTE: Since `self.layer` is passed as an `objc.c.id`, it's
    //       automatically retained when the block is copied, so we
    //       don't need to retain it ourselves like with the surface.

    // Counted before the block exists, so a renderer that asks in between
    // sees the present as queued rather than as landed.
    _ = state.pending.fetchAdd(1, .seq_cst);

    var block = SetSurfaceBlock.init(.{
        .layer = self.layer.value,
        .surface = surface,
        .state = state,
    }, &setSurfaceCallback);
""",
    "IOSurfaceLayer.zig setSurface",
)

layer = replace_exact(
    layer,
    """pub inline fn setSurfaceSync(self: *IOSurfaceLayer, surface: *IOSurface) void {
    self.layer.setProperty("contents", surface);
}

const SetSurfaceBlock = objc.Block(struct {
    layer: objc.c.id,
    surface: *IOSurface,
}, .{}, void);
""",
    """pub inline fn setSurfaceSync(
    self: *IOSurfaceLayer,
    surface: *IOSurface,
    state: *PresentState,
) void {
    self.layer.setProperty("contents", surface);
    state.displayed.store(@intFromPtr(surface), .seq_cst);
}

const SetSurfaceBlock = objc.Block(struct {
    layer: objc.c.id,
    surface: *IOSurface,
    state: *PresentState,
}, .{}, void);
""",
    "IOSurfaceLayer.zig setSurfaceSync + block",
)

layer = replace_exact(
    layer,
    """    // See explanation of why we retain and release in `setSurface`.
    defer surface.release();
""",
    """    // See explanation of why we retain and release in `setSurface`.
    defer surface.release();
    // Landed or discarded, this present is no longer queued.
    defer _ = block.state.pending.fetchSub(1, .seq_cst);
""",
    "IOSurfaceLayer.zig callback pending",
)

layer = replace_exact(
    layer,
    """
    layer.setProperty("contents", surface);
}
""",
    """
    layer.setProperty("contents", surface);
    block.state.displayed.store(@intFromPtr(surface), .seq_cst);
}
""",
    "IOSurfaceLayer.zig callback displayed",
)

pending.append((layer_path, layer, "IOSurfaceLayer.zig"))

# ──────────────────────────────────────────────────────────────────────
# 2. Metal.zig — own the state, thread it through present, answer the question.
# ──────────────────────────────────────────────────────────────────────
metal = metal_path.read_text()

metal = replace_exact(
    metal,
    """layer: IOSurfaceLayer,
""",
    f"""layer: IOSurfaceLayer,

/// {MARKER}
/// Which of our surfaces the compositor holds — see `canDrawInto`.
present_state: IOSurfaceLayer.PresentState = .{{}},
""",
    "Metal.zig present_state field",
)

metal = replace_exact(
    metal,
    """pub inline fn present(self: *Metal, target: Target, sync: bool) !void {
    // iOS: always present synchronously — the render loop already runs on
    // the main thread, so the async GCD hop is unnecessary overhead.
    if (comptime builtin.os.tag == .ios) {
        try self.layer.setSurface(target.surface);
        return;
    }
    if (sync) {
        self.layer.setSurfaceSync(target.surface);
    } else {
        try self.layer.setSurface(target.surface);
    }
}
""",
    f"""pub inline fn present(self: *Metal, target: Target, sync: bool) !void {{
    // iOS: always present synchronously — the render loop already runs on
    // the main thread, so the async GCD hop is unnecessary overhead.
    if (comptime builtin.os.tag == .ios) {{
        try self.layer.setSurface(target.surface, &self.present_state);
        return;
    }}
    if (sync) {{
        self.layer.setSurfaceSync(target.surface, &self.present_state);
    }} else {{
        try self.layer.setSurface(target.surface, &self.present_state);
    }}
}}

/// {MARKER}
/// Whether `target` may be drawn into now.
///
/// The swap chain frees a target when the GPU has finished it, but the
/// compositor keeps reading it until the main thread has moved the layer on
/// to a later frame. Drawing into it before then puts a half-written frame on
/// screen. Refused while any present is still queued on the main thread, and
/// while this surface is the one on screen.
pub inline fn canDrawInto(self: *const Metal, target: *const Target) bool {{
    if (self.present_state.pending.load(.seq_cst) != 0) return false;
    return self.present_state.displayed.load(.seq_cst) != @intFromPtr(target.surface);
}}
""",
    "Metal.zig present + canDrawInto",
)

pending.append((metal_path, metal, "Metal.zig"))

# ──────────────────────────────────────────────────────────────────────
# 3. generic.zig — skip the draw, keep the frame dirty.
# ──────────────────────────────────────────────────────────────────────
generic = generic_path.read_text()

generic = replace_exact(
    generic,
    """            // Wait for a frame to be available.
            const frame = try self.swap_chain.nextFrame();
            errdefer self.swap_chain.releaseFrame();
""",
    f"""            // Wait for a frame to be available.
            const frame = try self.swap_chain.nextFrame();
            errdefer self.swap_chain.releaseFrame();

            // {MARKER}
            // The compositor may still be reading this frame's target: the
            // swap chain only knows the GPU is done with it, not that the
            // layer has moved on. Draw nothing this tick rather than into a
            // surface that is on screen, and keep the frame dirty so the
            // next tick draws it.
            if (@hasDecl(GraphicsAPI, "canDrawInto") and
                !self.api.canDrawInto(&frame.target))
            {{
                self.cells_rebuilt = true;
                self.swap_chain.releaseFrame();
                return;
            }}
""",
    "generic.zig drawFrame skip",
)

pending.append((generic_path, generic, "generic.zig"))

# ──────────────────────────────────────────────────────────────────────
# Postconditions.
# ──────────────────────────────────────────────────────────────────────
require(layer.count("state: *PresentState") == 3, "IOSurfaceLayer.zig: state threaded through setSurface, setSurfaceSync and the block")
require(metal.count("&self.present_state") == 3, "Metal.zig: every present path carries the state")
require(generic.count(MARKER) == 1, "generic.zig: marker present once")

for path, text, label in pending:
    path.write_text(text)
    print(f"[+] patched {label}")
PY

echo "[+] present backpressure: the renderer no longer draws into a surface the compositor may still hold"
