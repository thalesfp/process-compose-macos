// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "process-compose-macos",
	platforms: [.macOS(.v14)],
	dependencies: [
		.package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
	],
	targets: [
		.target(name: "ProcessComposeCore", dependencies: ["Yams"]),
		.executableTarget(name: "process-compose-macos", dependencies: ["ProcessComposeCore"]),
		.testTarget(name: "ProcessComposeCoreTests", dependencies: ["ProcessComposeCore"]),
	]
)
