// swift-tools-version: 6.0
// The PrepareMe file service (plan phase 1): the Mac serves one folder to paired phones on the home network, and the
// probe app (app/Probe) checks, downloads and verifies from it. PrepareMeShared is what both sides use; PrepareMeServer
// and the prepareme-service command are the Mac's. One outside package, Apple's swift-certificates (with swift-asn1 and
// swift-crypto, which it brings): the Mac's pairing certificate is made in Swift since 2026-10-28, not by
// /usr/bin/openssl (owner's ruling; docs/probe.md). Until then there was no dependency outside Apple's own frameworks.
import PackageDescription

let package = Package(
    name: "PrepareMeService",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PrepareMeShared", targets: ["PrepareMeShared"]),
        .library(name: "PrepareMeServer", targets: ["PrepareMeServer"]),
        .executable(name: "prepareme-service", targets: ["prepareme-service"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates", from: "1.21.1"),
        .package(url: "https://github.com/apple/swift-asn1", from: "1.7.3"),
    ],
    targets: [
        // Its resources, each written and pinned by a Python test so the Mac keeps no copy: the lists job's needs
        // table (readiness/tests/test_needs.py; phase L, choice 4) and Our Home pages' styles, script and words for the
        // editor's preview (packer/tests/test_steps.py; Our Home plan, Task 2.5).
        .target(name: "PrepareMeShared", resources: [.copy("Resources/household-needs.json"),
                                                     .copy("Resources/our-home-page.json")]),
        .target(name: "PrepareMeServer", dependencies: [
            "PrepareMeShared",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
        ]),
        .executableTarget(name: "prepareme-service", dependencies: ["PrepareMeServer", "PrepareMeShared"]),
        // Fixtures: files the tests read by path, such as the manifest the packer wrote (plan phase 2).
        .testTarget(name: "PrepareMeSharedTests", dependencies: ["PrepareMeShared"], exclude: ["Fixtures"]),
        // Fixtures: an identity made by the old /usr/bin/openssl `make`, read by path.
        .testTarget(name: "PrepareMeServerTests", dependencies: [
                        "PrepareMeServer", "PrepareMeShared", .product(name: "X509", package: "swift-certificates"),
                    ],
                    exclude: ["Fixtures"]),
    ]
)
