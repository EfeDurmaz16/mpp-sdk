// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SolanaPayKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "SolanaPayKit",
            targets: ["SolanaPayKit"]
        ),
    ],
    targets: [
        .target(name: "SolanaPayKit"),
        // Cross-SDK conformance-vector runner CLI. Reads one vector as JSON
        // on stdin and emits one RunnerResult line on stdout, honoring the
        // contract in harness/src/conformance/ts-runner.ts. Swift is a
        // client-only SDK: it covers build-transaction and canonical-bytes
        // and emits an unsupported-mode reject for verify-transaction.
        .executableTarget(
            name: "mpp-conformance",
            dependencies: ["SolanaPayKit"]
        ),
        .testTarget(
            name: "SolanaPayKitTests",
            dependencies: ["SolanaPayKit"]
        ),
    ]
)
