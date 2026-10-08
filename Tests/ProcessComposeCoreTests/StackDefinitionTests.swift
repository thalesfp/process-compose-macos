import Foundation
import Testing

@testable import ProcessComposeCore

private let configPath = "/stack/process-compose.yaml"

/// Reads the config at `configPath` as the app would launch it from `/work`, with the
/// given files standing in for the disk.
private func read(
	_ files: [String: String],
	environment: [String: String] = [:]
) throws -> [String: DefinedProcess] {
	let plan = ServerLaunchPlan(
		executablePath: "/bin/process-compose",
		configurationPath: configPath,
		workingDirectoryPath: "/work",
		port: 28080
	)!

	let processes = try StackDefinition.processes(for: plan, environment: environment) { url in
		guard let text = files[url.path] else { throw CocoaError(.fileReadNoSuchFile) }
		return text
	}

	return Dictionary(uniqueKeysWithValues: processes.map { ($0.name, $0) })
}

struct StackDefinitionTests {
	@Test("lists every process the config defines, with its namespace and working directory")
	func listsTheConfigsProcesses() throws {
		let processes = try read([
			configPath: """
			processes:
			  web:
			    command: npm start
			    namespace: frontend
			    working_dir: shop/web
			  migrate:
			    command: ./migrate
			    working_dir: data
			""",
		])

		#expect(processes["web"]?.namespace == "frontend")
		#expect(processes["web"]?.configuration.workingDir == "shop/web")
		#expect(processes["migrate"]?.namespace == "default")
		#expect(processes["migrate"]?.stoppedState.status == .stopped)
	}

	@Test("reads what decides a process's kind and start order")
	func readsKindAndDependencies() throws {
		let processes = try read([
			configPath: """
			processes:
			  api:
			    depends_on:
			      db:
			        condition: process_healthy
			      cache: {}
			    availability:
			      restart: always
			    watch:
			      paths:
			        - path: .
			  db: {}
			  cache: {}
			""",
		])

		#expect(processes["api"]?.configuration.dependsOn == ["cache", "db"])
		#expect(processes["api"]?.configuration.restartsAutomatically == true)
		#expect(processes["api"]?.configuration.hasWatcher == true)
		#expect(processes["db"]?.configuration.restartsAutomatically == false)
	}

	@Test("shows a disabled process as disabled")
	func showsDisabledProcesses() throws {
		let processes = try read([configPath: "processes:\n  relay:\n    disabled: true\n"])

		#expect(processes["relay"]?.stoppedState.status == .disabled)
	}

	@Test("lets is_disabled switch back on what disabled switched off")
	func isDisabledOverridesDisabled() throws {
		let processes = try read([configPath: "processes:\n  relay:\n    disabled: true\n    is_disabled: \"false\"\n"])

		#expect(processes["relay"]?.isDisabled == false)
	}

	@Test("starts an MCP process disabled, as the server does")
	func disablesMCPProcesses() throws {
		let processes = try read([configPath: "processes:\n  tools:\n    mcp:\n      arguments: []\n"])

		#expect(processes["tools"]?.isDisabled == true)
	}

	@Test("names replicas the way the server does, padded to the width of the count")
	func namesReplicas() throws {
		let processes = try read([
			configPath: "processes:\n  web:\n    replicas: 2\n  big:\n    replicas: 10\n  one:\n    replicas: 1\n",
		])

		#expect(processes.keys.sorted().filter { $0.hasPrefix("web") } == ["web-0", "web-1"])
		#expect(processes["big-00"] != nil)
		#expect(processes["big-09"] != nil)
		#expect(processes["one"] != nil)
	}

	@Test("expands a variable from the environment the server gets")
	func expandsFromTheEnvironment() throws {
		let processes = try read(
			[configPath: "processes:\n  web:\n    working_dir: ${REPO}/web\n"],
			environment: ["REPO": "shop"]
		)

		#expect(processes["web"]?.configuration.workingDir == "shop/web")
	}

	@Test("takes a variable from .env where the server runs before the environment")
	func prefersTheDotEnv() throws {
		let processes = try read(
			[
				configPath: "processes:\n  web:\n    working_dir: ${REPO}/web\n",
				"/work/.env": "# local\nexport REPO=\"from-dotenv\"\n",
			],
			environment: ["REPO": "from-environment"]
		)

		#expect(processes["web"]?.configuration.workingDir == "from-dotenv/web")
	}

	@Test("uses a variable's default when it is empty")
	func usesTheDefault() throws {
		let processes = try read([configPath: "processes:\n  web:\n    namespace: ${SPACE:-frontend}\n"])

		#expect(processes["web"]?.namespace == "frontend")
	}

	@Test("leaves a bare $NAME as it is and reads $$ as one $")
	func leavesBareDollarsAlone() throws {
		let expanded = try EnvironmentExpansion.expand("echo $HOME $${HOME} \\\\n") { _ in "/Users/me" }

		#expect(expanded == "echo $HOME ${HOME} \\n")
	}

	@Test("refuses a substitution it cannot reproduce, rather than guess")
	func refusesUnsupportedSubstitutions() {
		#expect(throws: StackDefinitionError.unsupportedExpansion("${#HOME}")) {
			try read([configPath: "processes:\n  web:\n    command: echo ${#HOME}\n"])
		}
	}

	@Test("refuses a ${ that is never closed, as the server does")
	func refusesAnUnclosedSubstitution() {
		#expect(throws: StackDefinitionError.unclosedExpansion) {
			try read([configPath: "# a ${ in a comment counts\nprocesses:\n  web:\n    command: run\n"])
		}
	}

	@Test("merges the file a config extends, anchoring its processes to its own directory")
	func mergesAnExtendedFile() throws {
		let processes = try read([
			"/base/common.yaml": """
			processes:
			  db:
			    working_dir: data
			    disabled: true
			  cache: {}
			""",
			configPath: """
			extends: ../base/common.yaml
			processes:
			  db:
			    namespace: storage
			    disabled: false
			  web:
			    working_dir: web
			""",
		])

		#expect(processes["db"]?.configuration.workingDir == "/base/data")
		#expect(processes["db"]?.namespace == "storage")
		#expect(processes["db"]?.isDisabled == true)
		#expect(processes["cache"]?.configuration.workingDir == "/base")
		#expect(processes["web"]?.configuration.workingDir == "web")
	}

	@Test("refuses a config that extends itself")
	func refusesAnExtendsLoop() {
		#expect(throws: StackDefinitionError.extendsLoop(configPath)) {
			try read([configPath: "extends: process-compose.yaml\nprocesses: {}\n"])
		}
	}

	@Test("merges a process over the one it extends")
	func mergesAnExtendedProcess() throws {
		let processes = try read([
			configPath: """
			processes:
			  base:
			    namespace: api
			    working_dir: api
			  worker:
			    extends: base
			    working_dir: api/worker
			""",
		])

		#expect(processes["worker"]?.namespace == "api")
		#expect(processes["worker"]?.configuration.workingDir == "api/worker")
		#expect(processes["base"] != nil)
	}

	@Test("refuses a process that extends one the config does not define")
	func refusesAnUnknownParent() {
		#expect(throws: StackDefinitionError.unknownParent(process: "worker", parent: "base")) {
			try read([configPath: "processes:\n  worker:\n    extends: base\n"])
		}
	}

	@Test("keeps the raw text where the config turns expansion off")
	func keepsRawTextWhenExpansionIsOff() throws {
		let processes = try read(
			[configPath: "disable_env_expansion: true\nprocesses:\n  web:\n    working_dir: ${REPO}/web\n"],
			environment: ["REPO": "shop"]
		)

		#expect(processes["web"]?.configuration.workingDir == "${REPO}/web")
	}

	@Test("lets a process's own keys win over the ones it merges from an anchor")
	func mergesYAMLAnchors() throws {
		let processes = try read([
			configPath: """
			x-base: &base
			  namespace: shared
			  working_dir: base
			processes:
			  web:
			    <<: *base
			    working_dir: web
			""",
		])

		#expect(processes["web"]?.namespace == "shared")
		#expect(processes["web"]?.configuration.workingDir == "web")
	}

	@Test("names the field that holds the wrong kind of value")
	func namesAMistypedField() {
		#expect(throws: StackDefinitionError.wrongKind(path: "processes.web.replicas")) {
			try read([configPath: "processes:\n  web:\n    replicas: lots\n"])
		}
	}

	@Test("says where the YAML stops making sense")
	func reportsBrokenYAML() {
		#expect(throws: StackDefinitionError.invalidYAML("did not find expected ',' or ']' on line 4")) {
			try read([configPath: "processes:\n  web:\n    command: [unclosed\n"])
		}
	}

	@Test("fails on a config file that is not there")
	func failsOnAMissingConfig() {
		#expect(throws: (any Error).self) {
			try read([:])
		}
	}
}
