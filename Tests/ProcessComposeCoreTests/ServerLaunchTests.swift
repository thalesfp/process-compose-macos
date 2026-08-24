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
				"--address", "localhost", "-p", "28080",
				"-t=false", "--keep-project",
			]
		)
		#expect(plan.workingDirectory.path == "/Users/dev/stack")
	}

	@Test("names the address, so the environment cannot open the server to the network")
	func namesTheAddress() throws {
		let plan = try #require(
			ServerLaunchPlan(
				executablePath: "/opt/homebrew/bin/process-compose",
				configurationPath: "/Users/dev/stack/process-compose.yaml",
				host: "localhost",
				port: 28080
			)
		)

		// PC_ADDRESS is what process-compose reads when no address is given.
		let environment = plan.environment(["PC_ADDRESS": "0.0.0.0"])

		#expect(plan.arguments.contains("--address"))
		#expect(plan.arguments.firstIndex(of: "--address").map { plan.arguments[$0 + 1] } == "localhost")
		#expect(environment["PC_ADDRESS"] == "0.0.0.0")
	}

	@Test("starts no server the app could not then talk to")
	func dropsTheVariablesThatWouldLockTheAppOut() throws {
		let plan = try #require(
			ServerLaunchPlan(
				executablePath: "/opt/homebrew/bin/process-compose",
				configurationPath: "/Users/dev/stack/process-compose.yaml",
				port: 28080
			)
		)

		let environment = plan.environment([
			"PC_NO_SERVER": "1",
			"PC_SOCKET_PATH": "/tmp/process-compose.sock",
			"PC_API_TOKEN": "secret",
			"PC_API_TOKEN_PATH": "/Users/dev/.pc-token",
			"PC_READ_ONLY": "1",
		])

		#expect(ServerLaunchPlan.refusedVariables.allSatisfy { environment[$0] == nil })
	}

	@Test("refuses a host the app could not then find the server on")
	func refusesAnUnusableHost() {
		#expect(
			ServerLaunchPlan(
				executablePath: "/opt/homebrew/bin/process-compose",
				configurationPath: "/Users/dev/stack/process-compose.yaml",
				host: " local host ",
				port: 28080
			) == nil
		)
	}

	@Test("takes the host the app looks for the server on")
	func takesTheCheckedHost() throws {
		let address = try #require(ServerAddress(host: " localhost ", port: 28080))
		let plan = try #require(
			ServerLaunchPlan(
				executablePath: "/opt/homebrew/bin/process-compose",
				configurationPath: "/Users/dev/stack/process-compose.yaml",
				address: address
			)
		)

		#expect(plan.host == "localhost")
		#expect(plan.arguments.firstIndex(of: "--address").map { plan.arguments[$0 + 1] } == "localhost")
	}

	@Test("finds a .pc_env that would leave the app unable to talk to the server")
	func findsARefusedSetting() throws {
		let plan = try #require(
			ServerLaunchPlan(
				executablePath: "/opt/homebrew/bin/process-compose",
				configurationPath: "/Users/dev/stack/process-compose.yaml",
				workingDirectoryPath: "/Users/dev",
				port: 28080
			)
		)

		let refused = plan.refusedSettings { file in
			file.path == "/Users/dev/stack/.pc_env" ? "FOO=1\nPC_NO_SERVER=1\n" : nil
		}

		#expect(refused == ["PC_NO_SERVER"])
		#expect(plan.refusedSettings { _ in "FOO=1" }.isEmpty)
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

	@Test("runs where the config's own paths resolve from")
	func usesTheChosenWorkingDirectory() throws {
		let plan = try #require(
			ServerLaunchPlan(
				executablePath: "/opt/homebrew/bin/process-compose",
				configurationPath: "/Users/dev/repos/stack/process-compose.yaml",
				workingDirectoryPath: "/Users/dev/repos",
				port: 28080
			)
		)

		#expect(plan.workingDirectory.path == "/Users/dev/repos")
	}

	@Test("checks the config without running anything")
	func buildsDryRunArguments() throws {
		let plan = try #require(
			ServerLaunchPlan(
				executablePath: "/opt/homebrew/bin/process-compose",
				configurationPath: "/Users/dev/stack/process-compose.yaml",
				port: 28080
			)
		)

		#expect(plan.validationArguments == ["up", "--dry-run", "-f", "/Users/dev/stack/process-compose.yaml"])
	}

	@Test("reads the fault out of what process-compose printed")
	func readsTheValidationFault() {
		let output = """
			\u{1b}[90m26-08-21 14:27:23.354\u{1b}[0m \u{1b}[31mFTL\u{1b}[0m \u{1b}[1mFailed to load project\u{1b}[0m error="watch path 'acme/v3' does not exist"

			"""

		#expect(
			ServerValidation.reason(in: output)
				== "Failed to load project: watch path 'acme/v3' does not exist"
		)
	}

	@Test("leaves a server built from several configs to the user")
	func ignoresSeveralConfigurations() {
		let learned = ServerLaunchPlan.learnedConfiguration(
			from: ["/Users/dev/stack/base.yaml", "/Users/dev/stack/extra.yaml"],
			current: ""
		)

		#expect(learned == nil)
	}

	@Test("takes the config from the server the app connected to")
	func learnsConfigurationFromTheServer() {
		let learned = ServerLaunchPlan.learnedConfiguration(
			from: ["/Users/dev/stack/process-compose.yaml", "/Users/dev/stack/.env"],
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

	@Test("knows which addresses are this machine")
	func recognisesLoopback() throws {
		#expect(try #require(ServerAddress(host: "localhost", port: 28080)).isLoopback)
		#expect(try #require(ServerAddress(host: "127.0.0.1", port: 28080)).isLoopback)
		#expect(try #require(ServerAddress(host: "build-box.local", port: 28080)).isLoopback == false)
	}

	@Test("runs the config with PWD where process-compose runs")
	func namesTheWorkingDirectoryInTheEnvironment() throws {
		let plan = try #require(
			ServerLaunchPlan(
				executablePath: "/opt/homebrew/bin/process-compose",
				configurationPath: "/Users/dev/repos/stack/process-compose.yaml",
				workingDirectoryPath: "/Users/dev/repos",
				port: 28080
			)
		)

		#expect(plan.environment(["PWD": "/Applications"])["PWD"] == "/Users/dev/repos")
	}

	@Test("finds the first install prefix that holds the binary")
	func discoversBinary() {
		let found = ServerBinary.discover { $0 == "/usr/local/bin/process-compose" }

		#expect(found == "/usr/local/bin/process-compose")
	}
}
