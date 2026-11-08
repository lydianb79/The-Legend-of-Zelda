// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZeldaRecomp",
    platforms: [.macOS(.v13)],
    targets: [
        // C runtime: recompiled game code (generated from your ROM), interpreter fallback, PPU/APU/MMC1.
        .target(
            name: "NESCore",
            path: "Sources/NESCore",
            cSettings: [
                .headerSearchPath("."),
                .unsafeFlags(["-Wno-unused-label", "-Wno-unused-variable"]),
            ]
        ),
        // Native macOS front-end: Metal renderer, settings UI, input, audio.
        .executableTarget(
            name: "ZeldaRecomp",
            dependencies: ["NESCore"],
            path: "Sources/ZeldaRecomp",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("GameController"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
