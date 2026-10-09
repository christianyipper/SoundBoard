// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Scorely",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Scorely",
            path: "Sources/Scorely"
        ),
        .testTarget(
            name: "ScorelyTests",
            dependencies: ["Scorely"],
            path: "Tests/ScorelyTests"
        )
    ]
)
