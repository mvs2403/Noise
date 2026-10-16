// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Noise",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "Noise", targets: ["Noise"]),
        .executable(name: "NoiseCheck", targets: ["NoiseCheck"]),
    ],
    targets: [
        .target(name: "CNoiseRuntime", publicHeadersPath: "include",
                cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio"), .linkedFramework("Foundation")]),
        .target(name: "NoiseAudio", dependencies: ["CNoiseRuntime"]),
        .executableTarget(name: "Noise", dependencies: ["NoiseAudio"]),
        .executableTarget(name: "NoiseCheck", dependencies: ["NoiseAudio", "CNoiseRuntime"]),
        .testTarget(name: "NoiseAudioTests", dependencies: ["NoiseAudio", "CNoiseRuntime"]),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
