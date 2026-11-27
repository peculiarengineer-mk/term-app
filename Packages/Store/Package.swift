// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Store",
    platforms: [.iOS(.v18)],
    products: [.library(name: "Store", targets: ["Store"])],
    dependencies: [.package(path: "../SSHKit")],
    targets: [
        .target(name: "StoreObjC"),
        .target(name: "Store", dependencies: ["StoreObjC"]),
        .testTarget(name: "StoreTests", dependencies: ["Store", .product(name: "SSHKit", package: "SSHKit")]),
    ],
    swiftLanguageModes: [.v6]
)
