// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SSHProof",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SSHProof", targets: ["SSHProof"]),
        .executable(name: "SSHProofKeygen", targets: ["SSHProofKeygen"])
    ],
    dependencies: [
        // 0.15.0 is the current Apple SwiftNIO SSH release tested with Swift 6.2.
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.103.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1")
    ],
    targets: [
        .target(name: "SSHProof", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "Crypto", package: "swift-crypto")
        ]),
        .executableTarget(name: "SSHProofKeygen", dependencies: ["SSHProof"]),
        .testTarget(name: "SSHProofTests", dependencies: ["SSHProof"])
    ]
)
