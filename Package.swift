// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HerdrStatusOverlay",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "HerdrStatusOverlay", targets: ["OverlayApp"]),
        .executable(name: "OverlaySelfCheck", targets: ["OverlaySelfCheck"]),
    ],
    targets: [
        .target(name: "OverlayCore"),
        .executableTarget(name: "OverlayApp", dependencies: ["OverlayCore"]),
        // XCTest is unavailable in Command Line Tools; this executable is the headless test suite.
        .executableTarget(name: "OverlaySelfCheck", dependencies: ["OverlayCore"]),
    ]
)
