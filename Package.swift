// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ComicViewer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ComicViewer", path: "Sources/ComicViewer"),
        .executableTarget(name: "MakeIcon", path: "Tools/MakeIcon"),
    ]
)
