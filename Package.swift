// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ComicViewer",
    platforms: [.macOS("15.0"), .iOS("18.0")],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/mtgto/Unrar.swift.git", from: "0.3.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Platform-neutral core (archives, page model, layout maths) — shared with a future iPad/iPhone app.
        .target(
            name: "ComicCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Unrar", package: "Unrar.swift"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/ComicCore"
        ),
        .executableTarget(name: "ComicViewer", dependencies: ["ComicCore"], path: "Sources/ComicViewer"),
        .executableTarget(name: "MakeIcon", path: "Tools/MakeIcon"),
        .executableTarget(name: "PanelDebug", dependencies: ["ComicCore"], path: "Tools/PanelDebug"),
        .testTarget(name: "ComicCoreTests", dependencies: ["ComicCore"], path: "Tests/ComicCoreTests"),
    ]
)
