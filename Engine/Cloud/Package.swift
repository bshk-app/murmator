// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MurmurCloud", platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "MurmurCloud", targets: ["MurmurCloud"])],
    dependencies: [.package(path: "../Core"), .package(path: "../Session"), .package(url: "https://github.com/bshk-app/ai-providers-swift.git", .upToNextMinor(from: "0.3.1"))],
    targets: [.target(name: "MurmurCloud", dependencies: [
        .product(name: "MurmurCore", package: "Core"),
        .product(name: "MurmurSession", package: "Session"),
        .product(name: "AIProvidersCore", package: "ai-providers-swift"), .product(name: "AIProvidersAuth", package: "ai-providers-swift"),
        .product(name: "AITextProviders", package: "ai-providers-swift"), .product(name: "AISpeechProviders", package: "ai-providers-swift"),
        .product(name: "AIServiceProviders", package: "ai-providers-swift"),
        .product(name: "DictatorCore", package: "ai-providers-swift"),
        .product(name: "DictatorAppleAuth", package: "ai-providers-swift")]),
        .testTarget(name: "MurmurCloudTests", dependencies: ["MurmurCloud"])], swiftLanguageModes: [.v5])
