// swift-tools-version: 6.1
import PackageDescription
let package = Package(name:"MurmurSpeech", platforms:[.macOS(.v15),.iOS(.v18)], products:[.library(name:"MurmurSpeech",targets:["MurmurSpeech"])], dependencies:[
 .package(path:"../Core"), .package(path:"../Whistle"), .package(path:"Vendor/mlx-audio-swift"),
 .package(url:"https://github.com/ml-explore/mlx-swift.git", exact:"0.31.6"),
 .package(url:"https://github.com/huggingface/swift-huggingface.git", exact:"0.10.0"),
 // No NemoTextProcessing: it serves FluidAudio's ITN/TTS only and adds a 197 MB binary.
 .package(url:"https://github.com/FluidInference/FluidAudio.git", revision:"a6b826ce9a09028fc685a4b32a8927ec920c3188", traits:[]),
 .package(url:"https://github.com/argmaxinc/argmax-oss-swift.git", exact:"1.1.0")
], targets:[.target(name:"MurmurSpeech",dependencies:[.product(name:"WhistleCPU",package:"Whistle",condition:.when(platforms:[.macOS])), .product(name:"MurmurCore",package:"Core"), .product(name:"MLXAudioSTT",package:"mlx-audio-swift"),.product(name:"MLXAudioVAD",package:"mlx-audio-swift"),.product(name:"MLX",package:"mlx-swift"),.product(name:"HuggingFace",package:"swift-huggingface"),.product(name:"FluidAudio",package:"FluidAudio"),.product(name:"WhisperKit",package:"argmax-oss-swift")],exclude:["CohereCoreML/LICENSE.txt","CanaryQualification/NOTICE.md","CanaryQualification/LICENSE-FluidAudio"], linkerSettings:[.linkedFramework("Accelerate")])],swiftLanguageModes:[.v5])
