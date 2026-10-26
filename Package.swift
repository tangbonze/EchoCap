// swift-tools-version: 6.0
import PackageDescription
import Foundation

// SwiftPM does not always pass the swift-testing macro plugin to the test
// target on this toolchain, so point at it explicitly.
let testingPluginPath = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let testingPluginAvailable = FileManager.default.fileExists(atPath: testingPluginPath)

var testSwiftSettings: [SwiftSetting] = []
if testingPluginAvailable {
    testSwiftSettings.append(.unsafeFlags([
        "-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
    ]))
}

let package = Package(
    name: "EchoCap",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "EchoCapCore", targets: ["EchoCapCore"]),
        .executable(name: "EchoCap", targets: ["EchoCap"]),
    ],
    targets: [
        .target(name: "EchoCapCore"),
        .executableTarget(name: "EchoCap", dependencies: ["EchoCapCore"]),
        .testTarget(
            name: "EchoCapTests",
            dependencies: ["EchoCapCore"],
            swiftSettings: testSwiftSettings
        ),
    ]
)
