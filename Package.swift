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
            url: "https://github.com/termio-sh/libghostty-swift/releases/download/storage.1.3.0/GhosttyKit.xcframework.zip",
            checksum: "75237f5a9fa4b4cb92081ed6ac4644c909ba2b452892ce81fe1e14d0679ded80"
        ),
        .binaryTarget(
            name: "GhosttyVt",
            url: "https://github.com/termio-sh/libghostty-swift/releases/download/storage.1.3.0/GhosttyVt.xcframework.zip",
            checksum: "24c69df4ca5dbcdff8e67268264269b3dad7a2cba6339caf9e7afc93264ad65c"
        ),
        .testTarget(
            name: "GhosttyKitTest",
            dependencies: ["GhosttyKit", "GhosttyTerminal", "GhosttyTheme", "ShellCraftKit", "GhosttyVt"],
            linkerSettings: [.linkedLibrary("c++")]
        ),
    ]
)
