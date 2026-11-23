// swift-tools-version: 6.2
// Polymer: module layout from Docs/DESIGN.md §3. Modules are added here as
// they get real code; the order below is the dependency order.
import PackageDescription

let package = Package(
    name: "Polymer",
    // macOS 15 for the Synchronization module (Mutex, Atomic) used by view invalidation.
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Polymer", targets: ["Polymer"]),
        .executable(name: "polymer", targets: ["PolymerTools"]),
    ],
    targets: [
        // Geometry, colour, IDs, logging, bytes, compression, JSON. Standard library only.
        .target(name: "PolymerBase"),

        // Platform interfaces (files, process) and the per-OS backends.
        // Backends are the only place `#if os(...)` is allowed.
        .target(name: "PolymerPlatform", dependencies: ["PolymerBase"]),
        .target(name: "PolymerPlatformWindows", dependencies: ["PolymerPlatform"]),
        .target(name: "PolymerPlatformMac", dependencies: ["PolymerPlatform"]),
        .target(name: "PolymerPlatformLinux", dependencies: ["PolymerPlatform"]),

        // Font parsing, outlines, the analytic rasteriser, text rendering.
        .target(name: "PolymerText", dependencies: ["PolymerBase"]),

        // Images (PNG), display lists and the CPU reference renderer.
        .target(name: "PolymerRender", dependencies: ["PolymerBase", "PolymerText"]),

        // Views, layout and state.
        .target(name: "PolymerUI", dependencies: ["PolymerBase", "PolymerText", "PolymerRender"]),

        // `import Polymer`: everything an app uses.
        .target(name: "Polymer", dependencies: ["PolymerBase", "PolymerText", "PolymerRender", "PolymerUI"]),

        // Checks run by `polymer check`, headless, the same on every OS.
        .target(name: "PolymerChecks", dependencies: ["PolymerBase", "PolymerPlatform", "PolymerText", "PolymerRender", "PolymerUI"]),

        // The `polymer` command.
        .executableTarget(
            name: "PolymerTools",
            dependencies: [
                "PolymerBase", "PolymerPlatform", "PolymerText", "PolymerRender", "PolymerUI", "PolymerChecks",
                .target(name: "PolymerPlatformWindows", condition: .when(platforms: [.windows])),
                .target(name: "PolymerPlatformMac", condition: .when(platforms: [.macOS])),
                .target(name: "PolymerPlatformLinux", condition: .when(platforms: [.linux])),
            ]
        ),
    ]
)
