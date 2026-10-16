// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "USBProbeCore", platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "USBProbeCore", targets: ["USBProbeCore"])],
    targets: [.target(name: "USBProbeCore"), .testTarget(name: "USBProbeCoreTests", dependencies: ["USBProbeCore"])])
