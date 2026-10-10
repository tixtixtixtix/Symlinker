// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Symlinker",
    platforms: [.macOS(.v14)],
    products: [
        // A droplet is a loadable bundle, so its product is a dynamic library.
        // Do not make it static: the app already carries DroppyKit, and a
        // second copy inside the droplet gives the same type two metadata
        // records, which fails every cast between them.
        .library(name: "Symlinker", type: .dynamic, targets: ["Symlinker"])
    ],
    dependencies: [
        .package(path: "/Users/dani/droppykit")
    ],
    targets: [
        .target(
            name: "Symlinker",
            dependencies: [.product(name: "DroppyKit", package: "droppykit")]
        ),
        .testTarget(name: "SymlinkerTests", dependencies: ["Symlinker"]),
        .executableTarget(
            name: "SymlinkerHarness",
            dependencies: [
                "Symlinker",
                .product(name: "DroppyKitHarness", package: "droppykit")
            ]
        )
    ]
)
