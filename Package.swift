// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Keylight", platforms: [.macOS(.v26)], targets: [.executableTarget(name: "Keylight", path: "Sources")], swiftLanguageModes: [.v5])
