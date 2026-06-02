// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SolanaPayKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        // Umbrella product: the one public surface. Re-exports PayCore,
        // Mpp, and X402 so callers keep a single `import SolanaPayKit`.
        .library(
            name: "SolanaPayKit",
            targets: ["SolanaPayKit"]
        ),
    ],
    targets: [
        // PayCore: protocol-agnostic Solana + crypto primitives.
        .target(name: "PayCore"),
        // Mpp protocol: depends only on PayCore.
        .target(
            name: "Mpp",
            dependencies: ["PayCore"]
        ),
        // X402 protocol: depends only on PayCore (never on Mpp).
        .target(
            name: "X402",
            dependencies: ["PayCore"]
        ),
        // Umbrella gate: depends on both protocols + PayCore, re-exports.
        .target(
            name: "SolanaPayKit",
            dependencies: ["PayCore", "Mpp", "X402"]
        ),
        .testTarget(
            name: "PayCoreTests",
            dependencies: ["PayCore"]
        ),
        .testTarget(
            name: "MppTests",
            dependencies: ["PayCore", "Mpp"]
        ),
        .testTarget(
            name: "X402Tests",
            dependencies: ["PayCore", "X402"]
        ),
    ]
)
