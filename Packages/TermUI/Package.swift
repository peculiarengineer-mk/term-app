// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TermUI",
    platforms: [.iOS(.v18)],
    products: [.library(name: "TermUI", targets: ["TermUI"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.11.2")],
    targets: [
        .target(name: "TermUI", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "TermUITests", dependencies: ["TermUI"]),
    ],
    swiftLanguageModes: [.v6]
)
