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
    dependencies: [
        .package(
            url: "https://github.com/firebase/firebase-ios-sdk.git",
            from: "11.8.0"
        ),
    ],
    targets: [
        .target(
            name: "ThoughtNudgeSDK",
            dependencies: [
                .product(name: "FirebaseMessaging", package: "firebase-ios-sdk"),
            ],
            path: "Sources/ThoughtNudgeSDK"
        ),
        .testTarget(
            name: "ThoughtNudgeSDKTests",
            dependencies: ["ThoughtNudgeSDK"],
            path: "Tests/ThoughtNudgeSDKTests"
        ),
    ]
)
