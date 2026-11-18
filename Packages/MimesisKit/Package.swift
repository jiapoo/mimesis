// swift-tools-version: 6.0
import PackageDescription

// Mimesis's shared code: everything both the Mac and the iOS app use.
let package = Package(
    name: "MimesisKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "MimesisKit", targets: ["MimesisKit"]),
    ],
    dependencies: [
        // Shared with Arete and Imago; the same version as project.yml pins.
        .package(url: "https://github.com/jiapoo/apple-media", exact: "1.16.0"),
        // The 3D engine, on trial (branch 3d).
        .package(url: "https://github.com/jiapoo/apple-motion", exact: "0.8.0"),
    ],
    targets: [
        .target(name: "MimesisKit", dependencies: [
            .product(name: "AreteMedia", package: "apple-media"),
            .product(name: "MotionCore", package: "apple-motion"),
            .product(name: "MotionKit", package: "apple-motion"),
        ]),
        // The Phase 0 masking test from the command line (Mac):
        // swift run -c release mask-probe <video> [--start s] [--seconds s] [--out folder]
        .executableTarget(name: "mask-probe", dependencies: ["MimesisKit"]),
        .testTarget(name: "MimesisKitTests", dependencies: ["MimesisKit"]),
    ]
)
