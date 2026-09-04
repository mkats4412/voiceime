// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "VoiceIME",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "VoiceIME"
        ),
        .testTarget(
            name: "VoiceIMETests",
            dependencies: ["VoiceIME"]
        ),
    ],
    swiftLanguageVersions: [.v6]
)

