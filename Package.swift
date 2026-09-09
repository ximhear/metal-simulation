// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GalaxyPhysics",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "GalaxyPhysics", targets: ["GalaxyPhysics"])],
    targets: [
        .target(name: "GalaxyPhysics", path: "GalaxyCollision/Physics"),
        .testTarget(name: "GalaxyPhysicsTests", dependencies: ["GalaxyPhysics"])
    ]
)
