// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MurmurSession",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "MurmurSession", targets: ["MurmurSession"]),
               .executable(name: "session-probe", targets: ["session-probe"])],
    dependencies: [.package(path: "../Core"), .package(path: "../Speech"), .package(path: "../Translation"), .package(path: "../PostProcessing")],
    targets: [
        .target(name: "MurmurSession", dependencies: [
            .product(name: "MurmurCore", package: "Core"),
            .product(name: "MurmurSpeech", package: "Speech"),
            .product(name: "MurmurTranslation", package: "Translation"),
            .product(name: "MurmurPostProcessing", package: "PostProcessing")
        ]),
        .executableTarget(name: "session-probe", dependencies: ["MurmurSession",
            .product(name: "MurmurCore", package: "Core"),
            .product(name: "MurmurSpeech", package: "Speech")]),
        .testTarget(name: "MurmurSessionTests", dependencies: ["MurmurSession"])
    ],
    swiftLanguageModes: [.v5]
)
