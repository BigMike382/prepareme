// swift-tools-version: 6.0
// Meaning search (docs/plans/2026-10-28-meaning-search.md): bge-small-en-v1.5 on Core ML. MeaningSearch is what the
// apps use; prepareme-meaning is the packer's and the search test's way to the same numbers on the Mac. No outside
// package, so the packer can build it with no network.
import PackageDescription

let package = Package(
    name: "Meaning",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "MeaningSearch", targets: ["MeaningSearch"]),
        .executable(name: "prepareme-meaning", targets: ["prepareme-meaning"]),
    ],
    targets: [
        .target(name: "MeaningSearch"),
        // News's grouping (docs/news.md): prepareme-meaning's `nearest` only, so the apps' MeaningSearch is unchanged
        .target(name: "MeaningNearest"),
        .executableTarget(name: "prepareme-meaning", dependencies: ["MeaningSearch", "MeaningNearest"]),
        .testTarget(name: "MeaningSearchTests", dependencies: ["MeaningSearch", "MeaningNearest"],
                    exclude: ["Fixtures"]),
    ]
)
