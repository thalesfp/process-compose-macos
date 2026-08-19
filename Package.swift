// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "Conductor",
	platforms: [.macOS(.v14)],
	targets: [
		.target(name: "ConductorCore"),
		.executableTarget(name: "Conductor", dependencies: ["ConductorCore"]),
		.testTarget(name: "ConductorCoreTests", dependencies: ["ConductorCore"]),
	]
)
