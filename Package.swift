// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OSXLLMTester",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OSXLLMTester", targets: ["OSXLLMTester"])
    ],
    targets: [
        .executableTarget(
            name: "OSXLLMTester",
            path: "Sources/OSXLLMTester"
        ),
        .testTarget(name: "OSXLLMTesterTests", dependencies: ["OSXLLMTester"])
    ]
)
