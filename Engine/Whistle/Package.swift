// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MurmurWhistle",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WhistleCPU", targets: ["WhistleCPU"]),
    .executable(name: "whistle-bench", targets: ["whistle-bench"]),
  ],
  targets: [
    .target(name: "WhistleCPU", linkerSettings: [.linkedFramework("Accelerate")]),
    .executableTarget(name: "whistle-bench", dependencies: ["WhistleCPU"]),
    .testTarget(name: "WhistleCPUTests", dependencies: ["WhistleCPU"]),
  ]
)
