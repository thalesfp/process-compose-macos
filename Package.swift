// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "process-compose-macos",
	platforms: [.macOS(.v14)],
	targets: [
		.target(name: "ProcessComposeCore"),
		.executableTarget(name: "process-compose-macos", dependencies: ["ProcessComposeCore"]),
		.testTarget(name: "ProcessComposeCoreTests", dependencies: ["ProcessComposeCore"]),
	]
)
