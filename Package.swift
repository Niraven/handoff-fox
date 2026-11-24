// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DesktopLink",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DesktopLink")
    ]
)
