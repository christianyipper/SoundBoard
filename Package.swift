// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SoundBoard",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "SoundBoard",
            path: "Sources/SoundBoard"
        ),
        .testTarget(
            name: "SoundBoardTests",
            dependencies: ["SoundBoard"],
            path: "Tests/SoundBoardTests"
        )
    ]
)
