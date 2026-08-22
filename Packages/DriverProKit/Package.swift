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
    .swiftLanguageMode(.v6),
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
        .library(name: "DPProtocolWebDAV", targets: ["DPProtocolWebDAV"]),
        .library(name: "DPProtocolS3", targets: ["DPProtocolS3"]),
        .library(name: "DPDatabase", targets: ["DPDatabase"]),
        .library(name: "DPBookmarks", targets: ["DPBookmarks"]),
        .library(name: "DPTransfer", targets: ["DPTransfer"]),
        .library(name: "DPServices", targets: ["DPServices"]),
        .library(name: "DPPresentation", targets: ["DPPresentation"]),
    ],

    dependencies: [
        // Citadel wraps swift-nio-ssh and adds the SFTP subsystem. Verified to build under Swift 6
        // strict concurrency by a throwaway spike before being adopted.
        //
        // Pinned exactly, not `from:`. Citadel depends on a *fork* of swift-nio-ssh, so a minor bump
        // could change the SSH transport underneath us without review. See ADR 009.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),

        // Soto's S3 client -> DPProtocolS3. Pinned exactly for the same reason as Citadel, and for one
        // more: Soto and Citadel share swift-nio, so a minor bump here can move the transport the SSH
        // backend is built on. See ADR 009 and the Package.resolved diff recorded in ADR 016.
        .package(url: "https://github.com/soto-project/soto.git", exact: "7.15.0"),

        // Soto's transport, depended on directly so `DPProtocolS3` can configure it. The version is the
        // one Soto resolves to; naming it here does not change the graph, it only makes the import legal.
        .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.36.0"),
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
            dependencies: ["DPCore", "DPTransfer", "DPCredentials"],
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
                .product(name: "Citadel", package: "Citadel"),
            ],
            swiftSettings: swiftSettings
        ),
        // The WebDAV backend. Foundation only — URLSession and XMLParser are the whole transport, so a
        // second protocol costs no dependency at all. Like DPProtocolSFTP, nothing imports it but the
        // composition root.
        .target(
            name: "DPProtocolWebDAV",
            dependencies: ["DPCore", "DPCredentials"],
            swiftSettings: swiftSettings
        ),
        // The S3 backend, and the only target allowed to import Soto. Same containment as Citadel in
        // DPProtocolSFTP: if Soto ever has to be replaced by a hand-rolled SigV4 client, the blast
        // radius is this directory.
        .target(
            name: "DPProtocolS3",
            dependencies: [
                "DPCore",
                "DPCredentials",
                .product(name: "SotoS3", package: "soto"),
                // Declared explicitly although Soto already brings it: this target configures the HTTP
                // client rather than taking Soto's default, because that default is a *browser-like*
                // one. See `S3Client.httpClient`.
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "DPProtocolS3Tests",
            dependencies: ["DPProtocolS3", "DPCore", "DPCredentials", "DPTestSupport"],
            swiftSettings: swiftSettings
        ),

        .testTarget(
            name: "DPProtocolWebDAVTests",
            dependencies: ["DPProtocolWebDAV", "DPCore", "DPCredentials", "DPTestSupport"],
            swiftSettings: swiftSettings
        ),

        // Persistence. Wraps the system SQLite3 — no third-party dependency — and knows nothing about
        // any DriverPro model, so DPBookmarks and (in M2) DPTransfer can both sit on top.
        .target(
            name: "DPDatabase",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "DPDatabaseTests",
            dependencies: ["DPDatabase"],
            swiftSettings: swiftSettings
        ),

        // Saved connections. Never touches secrets — those stay in DPCredentials and the Keychain.
        .target(
            name: "DPBookmarks",
            dependencies: ["DPCore", "DPDatabase"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "DPBookmarksTests",
            dependencies: ["DPBookmarks", "DPCore", "DPDatabase"],
            swiftSettings: swiftSettings
        ),

        // The transfer engine. Reaches backends only through Session and SessionFactory, so it depends
        // on no protocol target.
        .target(
            name: "DPTransfer",
            dependencies: ["DPCore", "DPDatabase"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "DPTransferTests",
            dependencies: ["DPTransfer", "DPCore", "DPTestSupport"],
            swiftSettings: swiftSettings
        ),

        // The composition root: the only target that knows which protocols exist and how the parts
        // fit together. Nothing imports it except the app.
        .target(
            name: "DPServices",
            dependencies: ["DPCore", "DPCredentials", "DPBookmarks", "DPDatabase", "DPTransfer",
                           "DPProtocolSFTP", "DPProtocolWebDAV"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "DPServicesTests",
            dependencies: ["DPServices", "DPCore", "DPCredentials", "DPTestSupport"],
            swiftSettings: swiftSettings
        ),

        // Observable state for a user interface. The one target permitted @MainActor; still no
        // SwiftUI, so `swift test` covers it.
        .target(
            name: "DPPresentation",
            // DPCredentials is here for `PrivateKeyLocator` and `SSHAgentClient`: the connection sheet
            // offers the keys in ~/.ssh and says whether an agent is running, and both are questions to
            // answer while the form is on screen rather than at connect time.
            dependencies: ["DPCore", "DPServices", "DPBookmarks", "DPTransfer", "DPCredentials"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "DPPresentationTests",
            dependencies: ["DPPresentation", "DPCore", "DPServices", "DPTestSupport", "DPDatabase",
                           "DPBookmarks", "DPCredentials"],
            swiftSettings: swiftSettings
        ),

        .testTarget(
            name: "DPProtocolSFTPTests",
            dependencies: ["DPProtocolSFTP", "DPCore", "DPCredentials", "DPTestSupport", "DPTransfer",
                           "DPServices", "DPBookmarks", "DPDatabase"],
            swiftSettings: swiftSettings
        ),
    ]
)
