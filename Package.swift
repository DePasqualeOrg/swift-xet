// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-xet",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Xet",
            targets: ["Xet"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Xet"
        ),
        .testTarget(
            name: "XetTests",
            dependencies: ["Xet"]
        ),
    ]
)
