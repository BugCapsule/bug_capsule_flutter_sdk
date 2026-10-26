// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "bug_capsule_native",
    platforms: [
        // The BugCapsule iOS SDK's minimum.
        .iOS("15.0")
    ],
    products: [
        .library(name: "bug-capsule-native", targets: ["bug_capsule_native"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        // The BugCapsule iOS SDK release with BugCapsuleCrashBridge.
        .package(url: "https://github.com/BugCapsule/bug_capsule_ios_sdk.git", exact: "0.4.1-beta.3"),
    ],
    targets: [
        .target(
            name: "bug_capsule_native",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "BugCapsule", package: "bug_capsule_ios_sdk"),
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
