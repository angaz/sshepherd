// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppUI",
    platforms: [.iOS(.v17)],
    products: [.library(name: "AppUI", targets: ["AppUI"])],
    targets: [
        .target(name: "AppUI"),
        .testTarget(name: "AppUITests", dependencies: ["AppUI"])
    ]
)
