// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "MurmurPostProcessing", platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "MurmurPostProcessing", targets: ["MurmurPostProcessing"]),
               .executable(name: "text-edit-probe", targets: ["text-edit-probe"])],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.10.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0")
    ], targets: [.target(name: "MurmurPostProcessing", dependencies: [
        .product(name: "MurmurCore", package: "Core"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXFast", package: "mlx-swift"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "Tokenizers", package: "swift-transformers")
    ]), .executableTarget(name: "text-edit-probe", dependencies: ["MurmurPostProcessing",
        .product(name: "MurmurCore", package: "Core"), .product(name: "MLX", package: "mlx-swift")]),
        .testTarget(name: "MurmurPostProcessingTests", dependencies: ["MurmurPostProcessing"])
    ], swiftLanguageModes: [.v5])
