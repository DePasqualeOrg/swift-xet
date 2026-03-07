// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Xet",
    platforms: [
        .macOS(.v13),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
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
