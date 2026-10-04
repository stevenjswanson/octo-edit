// swift-tools-version: 6.2
import PackageDescription

// Swift 5 language mode (on the Swift 6 toolchain) for targets that wrap
// AVFoundation / Speech, whose callback APIs predate strict concurrency.
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "OctoEdit",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "octoedit", targets: ["octoedit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Core: pure data model + operations. Foundation only.
        .target(name: "Core"),

        // Shared libraries.
        .target(name: "Align", dependencies: ["Core"]),
        .target(name: "MarkupGrammar", dependencies: ["Core"]),
        .target(name: "Naming", dependencies: ["Core"]),

        // Load / Save: the on-disk format.
        .target(name: "Load", dependencies: ["Core", "Align", "MarkupGrammar", "Yams"]),
        .target(name: "Save", dependencies: ["Core", "MarkupGrammar"]),

        // Ingest is pure logic; speech recognition and audio analysis are injected
        // through Core's Transcriber / EnvelopeAnalyzer protocols.
        .target(name: "Ingest", dependencies: ["Core", "Align"]),
        .target(name: "Transcribe", dependencies: ["Core"], swiftSettings: swift5),
        .target(name: "Waveform", dependencies: ["Core"], swiftSettings: swift5),

        // Render: composition + export.
        .target(name: "Render", dependencies: ["Core"], swiftSettings: swift5),

        // CLI composition root.
        .executableTarget(
            name: "octoedit",
            dependencies: [
                "Core", "Ingest", "Load", "Save", "Render", "Naming", "Transcribe", "Waveform",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swift5
        ),

        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "AlignTests", dependencies: ["Core", "Align"]),
        .testTarget(name: "FormatTests", dependencies: ["Core", "Load", "Save", "MarkupGrammar"]),
        .testTarget(name: "IngestTests", dependencies: ["Core", "Ingest", "Align", "Waveform", "Transcribe"], swiftSettings: swift5),
        .testTarget(name: "RenderTests", dependencies: ["Core", "Render"], swiftSettings: swift5),
        .testTarget(name: "NamingTests", dependencies: ["Core", "Naming"]),
        .testTarget(name: "ArchitectureTests"),
    ]
)
