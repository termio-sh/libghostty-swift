#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# Every step below used to detect "already applied" by grepping for the *old*
# anchor, so an upstream rename read as success and the step quietly did
# nothing. Each step now decides between three outcomes explicitly:
#
#   - the patched form is already present  -> skip, say so
#   - the anchor is present exactly once   -> transform
#   - anything else                        -> hard failure
#
# and nothing is written to disk until all four steps have succeeded.

python3 - "$SOURCE_DIR" <<'PYEOF'
import sys
from pathlib import Path

source_dir = Path(sys.argv[1])

# Staged writes. Nothing reaches disk until every transformation has succeeded,
# so a late failure can never leave a half-patched tree behind.
pending = []
messages = []


def stage(path, text, label):
    pending.append((path, text, label))


def load(rel_path):
    """Read a file that must exist. A missing file is an error, never a skip."""
    path = source_dir / rel_path
    if not path.is_file():
        print(f"[-] missing file: {rel_path}")
        sys.exit(1)
    return path, path.read_text()


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
# 1. cf_release_thread — ignore loop.run errors on iOS
#    The kqueue-based event loop panics on the iOS simulator (mach ports).
# ──────────────────────────────────────────────────────────────────────
cf_path, cf = load("src/os/cf_release_thread.zig")
cf_old = "    try self.loop.run(.until_done);"
cf_new = (
    '    self.loop.run(.until_done) catch |err| '
    '{ log.warn("cf release loop failed err={}", .{err}); return; };'
)
if cf_new in cf:
    messages.append("[+] cf_release_thread already patched")
else:
    # There is a second, already-guarded `self.loop.run(.until_done)` in the
    # abnormal-exit drain path; only the bare `try` form is ours.
    cf = replace_exact(cf, cf_old, cf_new, "cf_release_thread loop.run")
    stage(cf_path, cf, "src/os/cf_release_thread.zig")
    messages.append("[+] patched cf_release_thread to ignore loop errors")

# ──────────────────────────────────────────────────────────────────────
# 2. Disable private window blur API (App Store compliance)
# ──────────────────────────────────────────────────────────────────────
embedded_path, embedded = load("src/apprt/embedded.zig")
blur_old = """    export fn ghostty_set_window_background_blur(
        app: *App,
        window: *anyopaque,
    ) void {
        // This is only supported on macOS
        if (comptime builtin.target.os.tag != .macos) return;

        const config = &app.config;

        // Do nothing if we don't have background transparency enabled
        if (config.@"background-opacity" >= 1.0) return;

        const nswindow = objc.Object.fromId(window);
        _ = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(),
            nswindow.msgSend(usize, objc.sel("windowNumber"), .{}),
            @intCast(config.@"background-blur".cval()),
        );
    }

    /// See ghostty_set_window_background_blur
    extern "c" fn CGSSetWindowBackgroundBlurRadius(*anyopaque, usize, c_int) i32;
    extern "c" fn CGSDefaultConnectionForThread() *anyopaque;"""

blur_new = """    export fn ghostty_set_window_background_blur(
        app: *App,
        window: *anyopaque,
    ) void {
        _ = app;
        _ = window;
        return;
    }"""

if "CGSSetWindowBackgroundBlurRadius" not in embedded:
    messages.append("[+] blur patch already applied")
else:
    # Reaching here means the private symbol is still referenced, so a missing
    # anchor is upstream drift — not an already-applied tree.
    embedded = replace_exact(
        embedded, blur_old, blur_new, "embedded.zig background blur function"
    )
    require(
        "CGSSetWindowBackgroundBlurRadius" not in embedded,
        "postcondition: private blur symbol still referenced in embedded.zig",
    )
    stage(embedded_path, embedded, "src/apprt/embedded.zig")
    messages.append("[+] patched: disabled private blur API")

# ──────────────────────────────────────────────────────────────────────
# 3. Metal framework linkage for pkg/macos
#
#    This step targeted `lib.linkFramework("IOSurface");` /
#    `module.linkFramework("IOSurface", .{});`. Upstream has since replaced
#    both with a table-driven `frameworks` array, so those anchors no longer
#    exist and this step has been a silent no-op that still printed success.
#    Recognize the current shape explicitly and fail if we recognize neither.
# ──────────────────────────────────────────────────────────────────────
macos_build_path, macos_build = load("pkg/macos/build.zig")
lib_anchor = '    lib.linkFramework("IOSurface");'
module_anchor = '        module.linkFramework("IOSurface", .{});'
table_anchor = (
    '    .{ .tag = .all, .name = "IOSurface", .headers = &.{"IOSurfaceRef.h"} },'
)

if 'lib.linkFramework("Metal")' in macos_build:
    messages.append("[+] Metal frameworks already linked")
elif lib_anchor in macos_build or module_anchor in macos_build:
    macos_build = replace_exact(
        macos_build,
        lib_anchor,
        lib_anchor
        + '\n    lib.linkFramework("Metal");'
        + '\n    lib.linkFramework("MetalKit");',
        "pkg/macos/build.zig lib.linkFramework",
    )
    macos_build = replace_exact(
        macos_build,
        module_anchor,
        module_anchor
        + '\n        module.linkFramework("Metal", .{});'
        + '\n        module.linkFramework("MetalKit", .{});',
        "pkg/macos/build.zig module.linkFramework",
    )
    stage(macos_build_path, macos_build, "pkg/macos/build.zig")
    messages.append("[+] patched: linked Metal frameworks")
elif table_anchor in macos_build:
    messages.append(
        "[+] Metal framework linkage not applicable: pkg/macos/build.zig is "
        "table-driven upstream"
    )
else:
    print(
        "[-] pkg/macos/build.zig: neither the per-call linkFramework anchors "
        "nor the upstream frameworks table were found"
    )
    sys.exit(1)

# ──────────────────────────────────────────────────────────────────────
# 4. Keep iOS a buildable target for the full libghostty
#
#    Upstream removed iOS from the Ghostty app in ghostty#13759/#13760: the
#    Xcode target, the xcframework packaging, and the iOS prong of
#    osVersionMin are gone, and `Config.init` now refuses `.ios` outright
#    unless the build is -Demit-lib-vt. This fork builds the *full*
#    libghostty for iOS — the companion mirror is a live surface, not a VT
#    snapshot — so both have to be put back:
#
#      a. drop the refusal, which is a policy check and not a capability one
#      b. reinstate an iOS deployment target, since osVersionMin(.ios) now
#         returns null and the target would build with no minimum at all
# ──────────────────────────────────────────────────────────────────────
config_path, config = load("src/build/Config.zig")

ios_guard = """        // The full Ghostty build no longer supports iOS; Fail early
        // with a clear message rather than partway through the build.
        if (result.result.os.tag == .ios and !emit_lib_vt) {
            std.log.err(
                "iOS is not a supported target for the full Ghostty build; " ++
                    "only libghostty-vt supports iOS (-Demit-lib-vt)",
                .{},
            );
            return error.UnsupportedTarget;
        }

"""

if ios_guard in config:
    config = config.replace(ios_guard, "", 1)
    require(
        "UnsupportedTarget" not in config,
        "postcondition: iOS target refusal still present in Config.zig",
    )
    messages.append("[+] patched: dropped the iOS build refusal")
elif "UnsupportedTarget" not in config:
    messages.append("[+] iOS build refusal already dropped")
else:
    print("[-] Config.zig still refuses a target but the known guard is gone")
    sys.exit(1)

ios_min = """        .ios => .{ .semver = .{
            .major = 15,
            .minor = 0,
            .patch = 0,
        } },

"""
macos_min_anchor = """        .macos => .{ .semver = .{
            .major = 13,
            .minor = 0,
            .patch = 0,
        } },

"""

if ios_min in config:
    messages.append("[+] iOS deployment target already patched")
else:
    config = replace_exact(
        config,
        macos_min_anchor,
        macos_min_anchor + ios_min,
        "Config.zig osVersionMin macOS prong",
    )
    messages.append("[+] patched: iOS deployment target -> 15.0")

# Both steps above edit the same file, so it is staged once, after both.
stage(config_path, config, "src/build/Config.zig")

# ──────────────────────────────────────────────────────────────────────
# 5. Compile the Metal shaders for iOS again
#
#    The same removal took the iOS arms out of MetallibStep.create, so it
#    returns null for iOS and SharedDeps then unwraps it:
#    "panic: attempt to use null value" at `self.metallib.?`. The renderer
#    is Metal on both Apple platforms, so the arms go back verbatim.
# ──────────────────────────────────────────────────────────────────────
metallib_path, metallib = load("src/build/MetallibStep.zig")

metallib_hunks = [
    (
        """    const sdk = switch (opts.target.result.os.tag) {
        .macos => "macosx",
""",
        """        .ios => switch (opts.target.result.abi) {
            // The iOS simulator uses the same SDK for Metal as the device,
            // but the minimum version tag causes different behaviors.
            .simulator => "iphoneos",
            else => "iphoneos",
        },
""",
        "MetallibStep sdk switch",
    ),
    (
        """    const platform_version_arg = switch (opts.target.result.os.tag) {
        .macos => "-mmacos-version-min",
""",
        """        .ios => switch (opts.target.result.abi) {
            .simulator => "-mios-simulator-version-min",
            else => "-mios-version-min",
        },
""",
        "MetallibStep platform version switch",
    ),
    (
        """    else switch (opts.target.result.os.tag) {
        .macos => "10.14",
""",
        """        .ios => "11.0",
""",
        "MetallibStep minimum version switch",
    ),
]

if '"iphoneos"' in metallib:
    messages.append("[+] Metal shader compilation for iOS already restored")
else:
    for anchor, addition, what in metallib_hunks:
        metallib = replace_exact(metallib, anchor, anchor + addition, what)
    require(
        "-mios-version-min" in metallib,
        "postcondition: MetallibStep still has no iOS platform version",
    )
    stage(metallib_path, metallib, "src/build/MetallibStep.zig")
    messages.append("[+] patched: Metal shaders compile for iOS again")

# ──────────────────────────────────────────────────────────────────────
# 6. Enable blocks when translating the Apple headers
#
#    Apple's headers declare block types (`CGPathApplyBlock` and friends), so
#    translating them needs `-fblocks`. Aro turns blocks on by itself only
#    when it can prove the target supports them, which it does for macOS and
#    not for iOS, so an iOS translation dies in CGPath.h with "blocks are not
#    enabled". Upstream passed the flag explicitly until translate-c was
#    refactored (ghostty c0c5473da) and it was dropped; upstream never built
#    this module for anything but macOS, so nothing there noticed.
# ──────────────────────────────────────────────────────────────────────
macos_build_path, macos_build = load("pkg/macos/build.zig")

if "-fblocks" in macos_build:
    messages.append("[+] macos_c translation already enables blocks")
else:
    macos_build = replace_exact(
        macos_build,
        """        ) } },
        .target = target,
        .optimize = optimize,
    });
""",
        """        ) } },
        .target = target,
        .optimize = optimize,
        .extra_args = &.{"-fblocks"},
    });
""",
        "pkg/macos/build.zig macos_c translation args",
    )
    stage(macos_build_path, macos_build, "pkg/macos/build.zig")
    messages.append("[+] patched: macos_c translation enables blocks")

# All transformations succeeded — commit them.
for path, body, _ in pending:
    path.write_text(body)

for message in messages:
    print(message)
PYEOF

echo "[+] all ios-fixes patches applied"
