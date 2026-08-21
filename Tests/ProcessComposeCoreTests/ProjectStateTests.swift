import Foundation
import Testing

@testable import ProcessComposeCore

struct ProjectStateTests {
	@Test("reads the config files the server runs the project from")
	func readsTheConfigFiles() throws {
		let payload = Data(#"""
		{"fileNames":["/Users/thales/repos/acme/process-compose.yaml"],"upTime":5152541832542,
		"processNum":23,"runningProcessNum":7,"version":"v1.122.0","projectName":"repos"}
		"""#.utf8)

		let state = try JSONDecoder().decode(ProjectState.self, from: payload)

		#expect(state.configFiles == ["/Users/thales/repos/acme/process-compose.yaml"])
	}

	@Test("still reads a project state from a server that names no config files")
	func copesWithoutConfigFiles() throws {
		let payload = Data(#"""
		{"upTime":5152541832542,"processNum":23,"runningProcessNum":7,
		"version":"v1.122.0","projectName":"repos"}
		"""#.utf8)

		let state = try JSONDecoder().decode(ProjectState.self, from: payload)

		#expect(state.configFiles == nil)
		#expect(state.projectName == "repos")
	}
}
