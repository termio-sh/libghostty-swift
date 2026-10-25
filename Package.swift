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
            url: "https://github.com/termio-sh/libghostty-swift/releases/download/storage.1.2.0/GhosttyKit.xcframework.zip",
            checksum: "d6629c55ab4f99b9b82f7364bf44e2f261ed2a86c5d26f50c37d8821cc01175b"
        ),
        .binaryTarget(
            name: "GhosttyVt",
            url: "https://github.com/termio-sh/libghostty-swift/releases/download/storage.1.2.0/GhosttyVt.xcframework.zip",
            checksum: "e23b2fadddde4e3f7300db33d37b545e731fdf13f21769294652f7c05aacd17c"
        ),
        .testTarget(
            name: "GhosttyKitTest",
            dependencies: ["GhosttyKit", "GhosttyTerminal", "GhosttyTheme", "ShellCraftKit", "GhosttyVt"],
            linkerSettings: [.linkedLibrary("c++")]
        ),
    ]
)
