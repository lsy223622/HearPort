// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HearPortReceiver",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "HearPortReceiver", targets: ["HearPortReceiver"])
    ],
    targets: [
        .target(name: "HearPortReceiver"),
        .testTarget(
            name: "HearPortReceiverTests",
            dependencies: ["HearPortReceiver"]
        )
    ]
)
