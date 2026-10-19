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
            name: "HearPortAtomics",
            path: "Sources/HearPortAtomics",
            publicHeadersPath: "include"
        ),
        .target(
            name: "HearPortOpusBridge",
            path: "Sources/HearPortOpusBridge",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../Vendor/opus/include")
            ],
            linkerSettings: [
                .linkedLibrary("opus")
            ]
        ),
        .target(
            name: "HearPortReceiver",
            dependencies: ["HearPortAtomics", "HearPortOpusBridge"]
        ),
        .testTarget(
            name: "HearPortReceiverTests",
            dependencies: ["HearPortReceiver", "HearPortOpusBridge"]
        )
    ]
)
