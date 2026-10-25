// swift-tools-version: 6.0
// Tools 6.0 is required: `.visionOS(.v2)` fails under 5.9 (found by running swift test, 2026-10-25).
import PackageDescription

let package = Package(
    name: "HITMCockpit",
    platforms: [.macOS(.v13), .visionOS(.v2)],
    products: [.library(name: "HITMCore", targets: ["HITMCore"])],
    targets: [
        .target(name: "HITMCore"),
        // UX prototype: PROTOTYPE SAMPLE DATA, flat desktop UI. Remove or replace once real agents exist.
        .executableTarget(name: "CockpitPrototype", dependencies: ["HITMCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // Live check of the OpenRouter gate: sends INVENTED samples only. Run manually.
        .executableTarget(name: "GateLiveCheck", dependencies: ["HITMCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // Live check of Planner + gate: the intent text is sent to the planner model. Run manually.
        .executableTarget(name: "PlannerLiveCheck", dependencies: ["HITMCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "HITMCoreTests", dependencies: ["HITMCore"])
    ]
)
