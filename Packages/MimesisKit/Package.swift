// swift-tools-version: 6.0
import PackageDescription

// Mimesis's shared code: everything both the Mac and the iOS app use.
let package = Package(
    name: "MimesisKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "MimesisKit", targets: ["MimesisKit"]),
    ],
    targets: [
        .target(name: "MimesisKit"),
        // The Phase 0 masking test from the command line (Mac):
        // swift run -c release mask-probe <video> [--start s] [--seconds s] [--out folder]
        .executableTarget(name: "mask-probe", dependencies: ["MimesisKit"]),
    ]
)
