// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MurmurCaptions",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MurmurCaptions", targets: ["MurmurCaptions"])],
    targets: [
        .target(name: "MurmurCaptions"),
        .testTarget(name: "MurmurCaptionsTests", dependencies: ["MurmurCaptions"])
    ],
    swiftLanguageModes: [.v5]
)
