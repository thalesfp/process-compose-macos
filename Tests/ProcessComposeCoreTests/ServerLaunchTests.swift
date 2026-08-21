import Foundation
import Testing

@testable import ProcessComposeCore

struct ServerLaunchTests {
	@Test("runs the config as a foreground project that outlives its processes")
	func buildsUpArguments() throws {
		let plan = try #require(
			ServerLaunchPlan(
				executablePath: "/opt/homebrew/bin/process-compose",
				configurationPath: "/Users/dev/stack/process-compose.yaml",
				port: 28080
			)
		)

		#expect(
			plan.arguments == [
				"up", "-f", "/Users/dev/stack/process-compose.yaml",
				"-p", "28080", "-t=false", "--keep-project",
			]
		)
		#expect(plan.workingDirectory.path == "/Users/dev/stack")
	}

	@Test("refuses a plan without a config file")
	func refusesEmptyConfiguration() {
		#expect(ServerLaunchPlan(executablePath: "/bin/pc", configurationPath: "  ", port: 28080) == nil)
	}

	@Test("puts the usual install prefixes back on the stack's PATH")
	func extendsPath() throws {
		let plan = try #require(
			ServerLaunchPlan(
				executablePath: "/opt/homebrew/bin/process-compose",
				configurationPath: "/Users/dev/stack/process-compose.yaml",
				port: 28080
			)
		)

		let path = plan.environment(["PATH": "/usr/bin:/bin"])["PATH"]

		#expect(path?.hasPrefix("/opt/homebrew/bin:") == true)
		#expect(path?.hasSuffix(":/usr/bin:/bin") == true)
		#expect(path?.components(separatedBy: "/opt/homebrew/bin").count == 2)
	}

	@Test("takes the config from the server the app connected to")
	func learnsConfigurationFromTheServer() {
		let learned = ServerLaunchPlan.learnedConfiguration(
			from: ["/Users/dev/stack/process-compose.yaml"],
			current: ""
		)

		#expect(learned == "/Users/dev/stack/process-compose.yaml")
	}

	@Test("leaves a config the user chose alone")
	func keepsTheChosenConfiguration() {
		let learned = ServerLaunchPlan.learnedConfiguration(
			from: ["/Users/dev/stack/process-compose.yaml"],
			current: "/Users/dev/other/process-compose.yaml"
		)

		#expect(learned == nil)
	}

	@Test("finds the first install prefix that holds the binary")
	func discoversBinary() {
		let found = ServerBinary.discover { $0 == "/usr/local/bin/process-compose" }

		#expect(found == "/usr/local/bin/process-compose")
	}
}
