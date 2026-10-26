// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GhosttyKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit"]),
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
        .library(name: "ShellCraftKit", targets: ["ShellCraftKit"]),
        .library(name: "GhosttyTheme", targets: ["GhosttyTheme"]),
        // libghostty-vt, the terminal core without ghostty's surface, for a
        // host that renders it itself. Built from the same ghostty commit as
        // `libghostty`, so the two can be linked into one app.
        .library(name: "GhosttyVt", targets: ["GhosttyVt"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/MSDisplayLink.git", from: "2.1.0"),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: ["libghostty"],
            path: "Sources/GhosttyKit",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit", "MSDisplayLink"],
            path: "Sources/GhosttyTerminal"
        ),
        .target(
            name: "ShellCraftKit",
            dependencies: ["GhosttyTerminal"],
            path: "Sources/ShellCraftKit"
        ),
        .target(
            name: "GhosttyTheme",
            dependencies: ["GhosttyTerminal"],
            path: "Sources/GhosttyTheme",
            exclude: ["LICENSE"]
        ),
        .binaryTarget(
            name: "libghostty",
            url: "https://github.com/termio-sh/libghostty-swift/releases/download/storage.1.2.1/GhosttyKit.xcframework.zip",
            checksum: "81b5e211735f557bd6e6b2c45f47bfff6115b05527198d14876ae92711be922d"
        ),
        .binaryTarget(
            name: "GhosttyVt",
            url: "https://github.com/termio-sh/libghostty-swift/releases/download/storage.1.2.1/GhosttyVt.xcframework.zip",
            checksum: "3dc9a77f96c4efa7df1ac3a9917ca4eba834eb8e0bb3472b37e62622dc6e4f0b"
        ),
        .testTarget(
            name: "GhosttyKitTest",
            dependencies: ["GhosttyKit", "GhosttyTerminal", "GhosttyTheme", "ShellCraftKit", "GhosttyVt"],
            linkerSettings: [.linkedLibrary("c++")]
        ),
    ]
)
