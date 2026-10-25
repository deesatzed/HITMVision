// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HITMCockpit",
    platforms: [.macOS(.v13), .visionOS(.v2)],
    products: [.library(name: "HITMCore", targets: ["HITMCore"])],
    targets: [
        .target(name: "HITMCore"),
        .testTarget(name: "HITMCoreTests", dependencies: ["HITMCore"])
    ]
)
