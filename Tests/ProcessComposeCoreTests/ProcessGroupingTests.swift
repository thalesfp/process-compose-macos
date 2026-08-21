import Foundation
import Testing

@testable import ProcessComposeCore

struct ProcessGroupingTests {
	@Test("reads the repo from a working directory inside it")
	func repoFromNestedDirectory() {
		#expect(ProcessGrouping.project(forWorkingDir: "acme/v3/packages/admin") == "acme")
	}

	@Test("uses the directory itself when the process runs at the repo root")
	func repoFromRootDirectory() {
		#expect(ProcessGrouping.project(forWorkingDir: "acme-mcp") == "acme-mcp")
	}

	@Test("looks through a leading ./")
	func stripsLeadingDotSlash() {
		#expect(ProcessGrouping.project(forWorkingDir: "./acme/api") == "acme")
	}

	@Test("leaves a process ungrouped when its path says nothing about a repo")
	func ungroupsUnknownPaths() {
		#expect(ProcessGrouping.project(forWorkingDir: "/Users/thales/repos/acme/api") == nil)
		#expect(ProcessGrouping.project(forWorkingDir: "") == nil)
		#expect(ProcessGrouping.project(forWorkingDir: nil) == nil)
	}

	@Test("lists one sidebar row per project")
	func listsOneRowPerProject() {
		let states: [ProcessState] = [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .completed),
			.init(name: "chatbot", namespace: "ai", status: .running, isRunning: true),
		]
		let projects = [
			"api": "acme", "worker": "acme", "chatbot": "acme-ai-chatbot",
		]

		let rows = ProcessGrouping.projects(for: states, projects: projects)

		#expect(rows.map(\.name) == ["acme", "acme-ai-chatbot"])
		#expect(rows[0].runningCount == 1)
		#expect(rows[0].processCount == 2)
	}

	@Test("counts a process the config disabled in a project's total")
	func countsDisabledProcesses() {
		let states: [ProcessState] = [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "relay", namespace: "api", status: .disabled),
		]

		let rows = ProcessGrouping.projects(for: states, projects: ["api": "acme", "relay": "acme"])

		#expect(rows[0].runningCount == 1)
		#expect(rows[0].processCount == 2)
	}

	@Test("sinks processes with no project below the named ones")
	func ungroupedSortsLast() {
		let states: [ProcessState] = [
			.init(name: "api", namespace: "api", status: .running),
			.init(name: "stray", namespace: "misc", status: .running),
			.init(name: "chatbot", namespace: "ai", status: .running),
		]
		let projects = ["api": "acme", "chatbot": "acme-ai-chatbot"]

		let rows = ProcessGrouping.projects(for: states, projects: projects)

		#expect(rows.map(\.name) == ["acme", "acme-ai-chatbot", "other"])
	}
}

struct StackSectionTests {
	private let services = ["v3-admin": ProcessKind.service, "api": .service]
	private let tasks = ["style-inputs": ProcessKind.task, "acme-docker": .task]

	@Test("names a namespace once, above the first section it owns")
	func namespaceHeadingAppearsOnce() {
		let states: [ProcessState] = [
			.init(name: "api", namespace: "api", status: .running),
			.init(name: "v3-admin", namespace: "web", status: .running),
		]

		let sections = ProcessGrouping.sections(for: states, kinds: services)

		#expect(sections.map(\.namespace) == ["api", "web"])
		#expect(sections.map(\.isFirstInNamespace) == [true, true])
	}

	@Test("splits a namespace that holds both into a services and a tasks section")
	func splitsMixedNamespace() {
		let states: [ProcessState] = [
			.init(name: "v3-admin", namespace: "web", status: .running),
			.init(name: "style-inputs", namespace: "web", status: .watching),
		]

		let sections = ProcessGrouping.sections(
			for: states,
			kinds: ["v3-admin": .service, "style-inputs": .task]
		)

		#expect(sections.map(\.kind) == [.service, .task])
		#expect(sections.map(\.showsKind) == [true, true])
		#expect(sections.map(\.isFirstInNamespace) == [true, false])
	}

	@Test("labels a namespace that is only tasks, so nothing looks like a dead service")
	func labelsTaskOnlyNamespace() {
		let states: [ProcessState] = [.init(name: "acme-docker", namespace: "deps", status: .completed)]

		let sections = ProcessGrouping.sections(for: states, kinds: tasks)

		#expect(sections.map(\.kind) == [.task])
		#expect(sections[0].showsKind)
	}

	@Test("leaves a namespace of only services unlabelled, since the rows say it")
	func leavesServiceOnlyNamespaceUnlabelled() {
		let states: [ProcessState] = [.init(name: "api", namespace: "api", status: .running)]

		let sections = ProcessGrouping.sections(for: states, kinds: services)

		#expect(!sections[0].showsKind)
	}

	@Test("gives every section a distinct identity")
	func sectionsAreDistinct() {
		let states: [ProcessState] = [
			.init(name: "acme-mcp", namespace: "ai", status: .completed),
			.init(name: "chatbot", namespace: "ai", status: .running),
			.init(name: "api", namespace: "api", status: .running),
		]

		let ids = ProcessGrouping.sections(
			for: states,
			kinds: ["acme-mcp": .task, "chatbot": .service, "api": .service]
		).map(\.id)

		#expect(Set(ids).count == ids.count)
	}
}

struct ProcessKindTests {
	@Test("a watcher that re-runs a finished command is a task")
	func watchedOneShotIsATask() {
		let kind = ProcessKind.of(
			state: .init(name: "style-inputs", status: .watching),
			configuration: .init(workingDir: "acme/v3/packages/acme-inputs", hasWatcher: true)
		)

		#expect(kind == .task)
	}

	@Test("a watched process that is kept alive is still a service")
	func watchedServiceStaysAService() {
		let kind = ProcessKind.of(
			state: .init(name: "acme-authenticator", status: .running, isRunning: true),
			configuration: .init(
				workingDir: "acme/functions/acme-authenticator",
				hasWatcher: true,
				restartsAutomatically: true
			)
		)

		#expect(kind == .service)
	}

	@Test("a one-shot that has finished is a task")
	func finishedOneShotIsATask() {
		let kind = ProcessKind.of(
			state: .init(name: "acme-docker", status: .completed),
			configuration: .init(workingDir: "acme")
		)

		#expect(kind == .task)
	}

	@Test("a running server is a service")
	func runningServerIsAService() {
		let kind = ProcessKind.of(
			state: .init(name: "api", status: .running, isRunning: true),
			configuration: .init(workingDir: "acme/api")
		)

		#expect(kind == .service)
	}

	@Test("a service that has not been started yet is still a service")
	func disabledServiceStaysAService() {
		let kind = ProcessKind.of(
			state: .init(name: "relay", status: .disabled),
			configuration: .init(workingDir: "acme/relay")
		)

		#expect(kind == .service)
	}

	@Test("reads the watcher and restart policy off the server's config payload")
	func decodesConfiguration() throws {
		let watched = #"{"workingDir":"acme/functions/x","watch":{"paths":[{"path":"."}]},"restartPolicy":{"restart":1}}"#
		let plain = #"{"workingDir":"acme/api","restartPolicy":{}}"#

		let a = try JSONDecoder().decode(ProcessConfiguration.self, from: Data(watched.utf8))
        let b = try JSONDecoder().decode(ProcessConfiguration.self, from: Data(plain.utf8))

		#expect(a.hasWatcher)
		#expect(a.restartsAutomatically)
		#expect(!b.hasWatcher)
		#expect(!b.restartsAutomatically)
	}
}
