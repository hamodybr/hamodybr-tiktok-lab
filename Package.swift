// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LabCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "LabCore", targets: ["LabCore"])],
    targets: [
        .target(name: "LabCore", path: "Core"),
        .testTarget(name: "LabCoreTests", dependencies: ["LabCore"], path: "Tests/LabCoreTests")
    ]
)
