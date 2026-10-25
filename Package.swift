// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FocusWidget",
    platforms: [.macOS(.v13)],
    targets: [
        // Storage + formatting, UI-free so it can be unit tested.
        .target(
            name: "FocusCore",
            path: "Sources/FocusCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The menu bar app.
        .executableTarget(
            name: "FocusWidget",
            dependencies: ["FocusCore"],
            path: "Sources/FocusWidget",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        // Smoke tests for FocusCore. An executable because CLT-only installs ship no XCTest.
        .executableTarget(
            name: "FocusCheck",
            dependencies: ["FocusCore"],
            path: "Sources/FocusCheck"
        ),
    ]
)
