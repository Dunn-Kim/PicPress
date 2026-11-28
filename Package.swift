// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MagicPics",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "MagicPics"),
        .testTarget(name: "MagicPicsTests", dependencies: ["MagicPics"]),
    ]
)
