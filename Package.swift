// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "PicPress",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PicPress"),
        .testTarget(name: "PicPressTests", dependencies: ["PicPress"]),
    ]
)
