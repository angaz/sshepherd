// swift-tools-version: 6.1
import Foundation
import PackageDescription

let nativeArtifact = "Native/SSHepherdTerminal.xcframework"
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasNativeArtifact = FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent(nativeArtifact).path)

let package = Package(
    name: "AppCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "AppCore", targets: ["AppCore"])],
    dependencies: [
        .package(path: "../AppUI"),
        .package(path: "../SecurityCore"),
        .package(path: "../SSHProof"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.103.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1")
    ],
    targets: [
        .target(name: "AppCore", dependencies: [
            "AppUI", "SecurityCore", "SSHProof",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "Crypto", package: "swift-crypto")
        ] + (hasNativeArtifact ? [.target(name: "SSHepherdTerminal")] : []),
                linkerSettings: [.linkedLibrary("c++")]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore"])
    ] + (hasNativeArtifact ? [.binaryTarget(name: "SSHepherdTerminal", path: nativeArtifact)] : [])
)
