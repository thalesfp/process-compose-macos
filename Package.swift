// swift-tools-version: 6.2
import PackageDescription

let approachable: [SwiftSetting] = [
	.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
	.enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
	name: "process-compose-macos",
	platforms: [.macOS(.v14)],
	dependencies: [
		.package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
	],
	targets: [
		.target(name: "ProcessComposeCore", dependencies: ["Yams"], swiftSettings: approachable),
		.executableTarget(name: "process-compose-macos", dependencies: ["ProcessComposeCore"], swiftSettings: approachable + [.defaultIsolation(MainActor.self)]),
		.testTarget(name: "ProcessComposeCoreTests", dependencies: ["ProcessComposeCore"], swiftSettings: approachable),
	]
)
