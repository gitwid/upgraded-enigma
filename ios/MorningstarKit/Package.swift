// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MorningstarKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MorningstarKit", targets: ["MorningstarKit"]),
    ],
    targets: [
        .target(name: "MorningstarKit"),
        .testTarget(
            name: "MorningstarKitTests",
            dependencies: ["MorningstarKit"],
            resources: [.copy("Resources/jcs_vectors.json")]
        ),
    ]
)
