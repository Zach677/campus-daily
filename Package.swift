// swift-tools-version: 6.0
import PackageDescription

// Logic layer: DailyCore, DailyHTTP, SchoolClient, HotWaterClient, LaundryClient, DailyStore (Swift 6 mode).
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
        .testTarget(name: "HotWaterClientTests", dependencies: ["DailyCore", "DailyHTTP", "HotWaterClient", "DailyStore", "DailyTestSupport"], swiftSettings: swift6),
    ],
    swiftLanguageModes: [.v6]
)
