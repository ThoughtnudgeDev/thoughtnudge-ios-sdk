// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ThoughtNudgeSDK",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "ThoughtNudgeSDK",
            targets: ["ThoughtNudgeSDK"]
        ),
    ],
    targets: [
        .target(
            name: "ThoughtNudgeSDK",
            path: "Sources/ThoughtNudgeSDK"
        ),
        .testTarget(
            name: "ThoughtNudgeSDKTests",
            dependencies: ["ThoughtNudgeSDK"],
            path: "Tests/ThoughtNudgeSDKTests"
        ),
    ]
)
