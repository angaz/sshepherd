// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SecurityCore", platforms: [.iOS(.v16), .macOS(.v13)], products: [.library(name: "SecurityCore", targets: ["SecurityCore"])], targets: [.target(name: "SecurityCore"), .testTarget(name: "SecurityCoreTests", dependencies: ["SecurityCore"])])
