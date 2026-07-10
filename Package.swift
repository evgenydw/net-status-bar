// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NetStatusBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "NetStatusBar", targets: ["NetStatusBar"])
    ],
    targets: [
        .executableTarget(
            name: "NetStatusBar",
            path: "Sources/NetStatusBar"
        )
    ]
)
