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
            url: "https://github.com/termio-sh/libghostty-swift/releases/download/storage.1.2.2/GhosttyKit.xcframework.zip",
            checksum: "7cb01e7d5bd548956478d851d84d88cca0797591e13e3e6cf870f3ae8f92194f"
        ),
        .binaryTarget(
            name: "GhosttyVt",
            url: "https://github.com/termio-sh/libghostty-swift/releases/download/storage.1.2.2/GhosttyVt.xcframework.zip",
            checksum: "d5f43d1818c4a129bad2c39c39b48f0f6e7eeecd3d11622f4d7dae293991f4d2"
        ),
        .testTarget(
            name: "GhosttyKitTest",
            dependencies: ["GhosttyKit", "GhosttyTerminal", "GhosttyTheme", "ShellCraftKit", "GhosttyVt"],
            linkerSettings: [.linkedLibrary("c++")]
        ),
    ]
)
