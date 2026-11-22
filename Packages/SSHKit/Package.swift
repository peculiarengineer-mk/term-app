// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSHKit",
    platforms: [.iOS(.v18)],
    products: [.library(name: "SSHKit", targets: ["SSHKit"])],
    targets: [
        .binaryTarget(name: "CLibSSH2", path: "Vendor/CLibSSH2.xcframework"),
        .target(name: "SSHKit", dependencies: ["CLibSSH2"]),
        .testTarget(name: "SSHKitTests", dependencies: ["SSHKit"]),
    ],
    swiftLanguageModes: [.v6]
)
