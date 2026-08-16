// swift-tools-version: 6.0
//
// DriverProKit — the entire DriverPro engine, with no UI anywhere in it.
//
// Everything here builds and tests from the terminal with `swift build` / `swift test`. No Xcode, no app
// launch. That is the whole reason the engine lives in a package rather than in the app target: a test
// suite you can run in two seconds is a test suite you will actually run.

import PackageDescription

/// Settings applied to every target in the package.
///
/// Swift 6 language mode turns data-race safety from a set of warnings into compiler errors. It is on
/// from the first commit deliberately — retrofitting concurrency correctness later is far more painful
/// than starting with it, and the compiler teaches you the rules as you go.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

let package = Package(
    name: "DriverProKit",

    // macOS 14 is Citadel's floor (verified by the SFTP spike), and nothing in the engine needs newer
    // system APIs. The *app* targets macOS 26; the engine deliberately asks for less so it stays easy
    // to test and reuse.
    platforms: [.macOS(.v14)],

    products: [
        .library(name: "DPCore", targets: ["DPCore"])
    ],

    dependencies: [],

    targets: [
        .target(
            name: "DPCore",
            swiftSettings: swiftSettings
        ),
        // Shared test material: an in-memory Session and the behavioural contract every backend must
        // satisfy. A library rather than a test target because two different test targets import it.
        .target(
            name: "DPTestSupport",
            dependencies: ["DPCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "DPCoreTests",
            dependencies: ["DPCore", "DPTestSupport"],
            swiftSettings: swiftSettings
        ),

    ]
)
