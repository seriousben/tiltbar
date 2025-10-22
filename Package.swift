// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TiltBar",
    platforms: [
        // Require macOS 13.0+ for modern async/await and MenuBarExtra support
        .macOS(.v13)
    ],
    products: [
        // The executable product that creates the status bar app
        .executable(
            name: "TiltBar",
            targets: ["TiltBar"]
        )
    ],
    targets: [
        .executableTarget(
            name: "TiltBar",
            dependencies: [],
            exclude: [
                // Info.plist is handled separately via linker settings, not as a bundle resource
                "Resources/Info.plist"
            ],
            resources: [
                // Declare PNG and ICO files as resources
                .copy("Resources/tilt-icon.png"),
                .copy("Resources/tilt-gray.png"),
                .copy("Resources/tilt-red.png"),
                .copy("Resources/tilt-icon.ico"),
                .copy("Resources/tilt-gray.ico"),
                .copy("Resources/tilt-red.ico")
            ],
            linkerSettings: [
                // Embed Info.plist into the executable
                // This tells the linker to create a special section in the binary
                // containing our Info.plist, which macOS reads to determine app behavior
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/TiltBar/Resources/Info.plist"
                ])
            ]
        )
    ]
)
