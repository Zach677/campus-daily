// swift-tools-version: 6.0
import PackageDescription

// New logic layer (R3): DailyCore, DailyHTTP, SchoolClient, HotWaterClient, LaundryClient, DailyStore (Swift 6 mode).
// The old WaterCore modules stay side by side (Swift 5 mode) until R4 removes them.
let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "XiaoRiChang",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DailyCore", targets: ["DailyCore"]),
        .library(name: "DailyHTTP", targets: ["DailyHTTP"]),
        .library(name: "SchoolClient", targets: ["SchoolClient"]),
        .library(name: "DailyStore", targets: ["DailyStore"]),
        .library(name: "HotWaterClient", targets: ["HotWaterClient"]),
        .library(name: "LaundryClient", targets: ["LaundryClient"]),
        // Legacy (deleted in R4)
        .library(name: "WaterCore", targets: ["WaterCore"]),
        .executable(name: "water-evidence-check", targets: ["WaterEvidenceCheck"]),
        .executable(name: "campus-read-check", targets: ["CampusReadCheck"]),
    ],
    targets: [
        .target(name: "DailyCore", swiftSettings: swift6),
        .target(name: "DailyHTTP", dependencies: ["DailyCore"], swiftSettings: swift6),
        .target(name: "SchoolClient", dependencies: ["DailyCore", "DailyHTTP"], swiftSettings: swift6),
        .target(name: "DailyStore", dependencies: ["DailyCore"], swiftSettings: swift6),
        .target(name: "HotWaterClient", dependencies: ["DailyCore", "DailyHTTP"], swiftSettings: swift6),
        .target(name: "LaundryClient", dependencies: ["DailyCore", "DailyHTTP"], swiftSettings: swift6),
        .target(name: "DailyTestSupport", dependencies: ["DailyCore", "DailyHTTP", "HotWaterClient"],
                path: "Tests/DailyTestSupport", swiftSettings: swift6),
        .testTarget(name: "DailyCoreTests", dependencies: ["DailyCore"], swiftSettings: swift6),
        .testTarget(name: "DailyHTTPTests", dependencies: ["DailyCore", "DailyHTTP", "DailyTestSupport"], swiftSettings: swift6),
        .testTarget(name: "SchoolClientTests", dependencies: ["DailyCore", "DailyHTTP", "SchoolClient", "DailyStore", "DailyTestSupport"], swiftSettings: swift6),
        .testTarget(name: "DailyStoreTests", dependencies: ["DailyCore", "DailyStore"], swiftSettings: swift6),
        .testTarget(name: "LaundryClientTests", dependencies: ["DailyCore", "DailyHTTP", "LaundryClient", "DailyStore", "DailyTestSupport"], swiftSettings: swift6),
        // Also depends on the legacy WaterCore for the signing/codec golden cross-checks (drop with WaterCore in R4).
        .testTarget(name: "HotWaterClientTests", dependencies: ["DailyCore", "DailyHTTP", "HotWaterClient", "DailyStore", "DailyTestSupport", "WaterCore"], swiftSettings: swift6),

        // Legacy (deleted in R4)
        .target(name: "WaterCore"),
        .executableTarget(name: "WaterEvidenceCheck", dependencies: ["WaterCore"]),
        .executableTarget(name: "CampusReadCheck", dependencies: ["WaterCore"]),
        .testTarget(name: "WaterCoreTests", dependencies: ["WaterCore"]),
    ],
    swiftLanguageModes: [.v5]
)
