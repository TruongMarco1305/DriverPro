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
        .library(name: "DPCore", targets: ["DPCore"]),
        .library(name: "DPCredentials", targets: ["DPCredentials"]),
        .library(name: "DPProtocolSFTP", targets: ["DPProtocolSFTP"]),
        .library(name: "DPTransfer", targets: ["DPTransfer"])
    ],

    dependencies: [
        // Citadel wraps swift-nio-ssh and adds the SFTP subsystem. Verified to build under Swift 6
        // strict concurrency by a throwaway spike before being adopted.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1")

        // Soto -> DPProtocolS3 (M4)
    ],

    targets: [
        .target(
            name: "DPCore",
            swiftSettings: swiftSettings
        ),
        // Shared test material: an in-memory Session and the behavioural contract every backend must
        // satisfy. A library rather than a test target because two different test targets import it.
        .target(
            name: "DPTestSupport",
            dependencies: ["DPCore", "DPTransfer"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "DPCoreTests",
            dependencies: ["DPCore", "DPTestSupport"],
            swiftSettings: swiftSettings
        ),

        // Secrets and trust. Note the dependency list: DPCore only. Keychain access and known_hosts
        // parsing need Security and CryptoKit, which are system frameworks — no third-party code is
        // involved in handling the user's passwords.
        .target(
            name: "DPCredentials",
            dependencies: ["DPCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "DPCredentialsTests",
            dependencies: ["DPCredentials", "DPCore"],
            swiftSettings: swiftSettings
        ),

        // The SFTP backend. This is the ONLY target allowed to import Citadel — that containment is
        // what would let libssh2 replace it without anything above noticing.
        .target(
            name: "DPProtocolSFTP",
            dependencies: [
                "DPCore",
                "DPCredentials",
                .product(name: "Citadel", package: "Citadel")
            ],
            swiftSettings: swiftSettings
        ),
        // The transfer engine. Reaches backends only through Session and SessionFactory, so it depends
        // on no protocol target.
        .target(
            name: "DPTransfer",
            dependencies: ["DPCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "DPTransferTests",
            dependencies: ["DPTransfer", "DPCore", "DPTestSupport"],
            swiftSettings: swiftSettings
        ),

        .testTarget(
            name: "DPProtocolSFTPTests",
            dependencies: ["DPProtocolSFTP", "DPCore", "DPCredentials", "DPTestSupport"],
            swiftSettings: swiftSettings
        )
    ]
)
