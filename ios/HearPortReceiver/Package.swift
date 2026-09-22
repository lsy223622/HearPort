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
        .target(
            name: "HearPortReceiver",
            swiftSettings: [
                .define("HEARPORT_SPAKE2_PROVIDER", .when(platforms: [.iOS]))
            ]
        ),
        .testTarget(
            name: "HearPortReceiverTests",
            dependencies: ["HearPortReceiver"]
        )
    ]
)
