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

	@Test("groups by project, then by stack")
	func groupsByProjectThenStack() {
		let states: [ProcessState] = [
			.init(name: "api", namespace: "api", status: .running),
			.init(name: "houston-api", namespace: "houston", status: .running),
			.init(name: "worker", namespace: "api", status: .running),
			.init(name: "chatbot", namespace: "ai", status: .running),
		]
		let projects = [
			"api": "acme", "worker": "acme", "houston-api": "acme",
			"chatbot": "acme-ai-chatbot",
		]

		let groups = ProcessGrouping.groups(for: states, projects: projects)

		#expect(groups.map(\.name) == ["acme", "acme-ai-chatbot"])
		#expect(groups[0].stacks.map(\.name) == ["api", "houston"])
		#expect(groups[0].stacks[0].processes.map(\.name) == ["api", "worker"])
		#expect(groups[1].stacks.map(\.name) == ["ai"])
	}

	@Test("keeps a single level when every process belongs to one project")
	func collapsesSingleProject() {
		let states: [ProcessState] = [
			.init(name: "api", namespace: "api", status: .running),
			.init(name: "web", namespace: "web", status: .running),
		]

		let groups = ProcessGrouping.groups(for: states, projects: ["api": "solo", "web": "solo"])

		#expect(groups.count == 1)
		#expect(groups[0].name == nil)
		#expect(groups[0].stacks.map(\.name) == ["api", "web"])
	}

	@Test("sinks processes with no project below the named ones")
	func ungroupedSortsLast() {
		let states: [ProcessState] = [
			.init(name: "api", namespace: "api", status: .running),
			.init(name: "stray", namespace: "misc", status: .running),
			.init(name: "chatbot", namespace: "ai", status: .running),
		]
		let projects = ["api": "acme", "chatbot": "acme-ai-chatbot"]

		let groups = ProcessGrouping.groups(for: states, projects: projects)

		#expect(groups.map(\.name) == ["acme", "acme-ai-chatbot", "other"])
	}
}

struct StackSectionTests {
	private let services = ["v3-admin": ProcessKind.service, "api": .service]
	private let tasks = ["style-inputs": ProcessKind.task, "acme-docker": .task]

	@Test("names the project once, above the first section it owns")
	func projectHeadingAppearsOnce() {
		let groups = [
			ProjectGroup(name: "acme", stacks: [
				StackGroup(name: "api", processes: [.init(name: "api", status: .running)]),
				StackGroup(name: "web", processes: [.init(name: "v3-admin", status: .running)]),
			]),
			ProjectGroup(name: "acme-mcp", stacks: [
				StackGroup(name: "ai", processes: [.init(name: "acme-mcp", status: .running)]),
			]),
		]

		let sections = ProcessGrouping.sections(for: groups, kinds: services)

		#expect(sections.map(\.namespace) == ["api", "web", "ai"])
		#expect(sections.map(\.isFirstInProject) == [true, false, true])
	}

	@Test("splits a namespace that holds both into a services and a tasks section")
	func splitsMixedNamespace() {
		let groups = [
			ProjectGroup(name: "acme", stacks: [
				StackGroup(name: "web", processes: [
					.init(name: "v3-admin", status: .running),
					.init(name: "style-inputs", status: .watching),
				]),
			]),
		]

		let sections = ProcessGrouping.sections(
			for: groups,
			kinds: ["v3-admin": .service, "style-inputs": .task]
		)

		#expect(sections.map(\.kind) == [.service, .task])
		#expect(sections.map(\.showsKind) == [true, true])
		#expect(sections.map(\.isFirstInNamespace) == [true, false])
	}

	@Test("labels a namespace that is only tasks, so nothing looks like a dead service")
	func labelsTaskOnlyNamespace() {
		let groups = [
			ProjectGroup(name: "acme", stacks: [
				StackGroup(name: "deps", processes: [.init(name: "acme-docker", status: .completed)]),
			]),
		]

		let sections = ProcessGrouping.sections(for: groups, kinds: tasks)

		#expect(sections.map(\.kind) == [.task])
		#expect(sections[0].showsKind)
	}

	@Test("leaves a namespace of only services unlabelled, since the rows say it")
	func leavesServiceOnlyNamespaceUnlabelled() {
		let groups = [
			ProjectGroup(name: "acme", stacks: [
				StackGroup(name: "api", processes: [.init(name: "api", status: .running)]),
			]),
		]

		let sections = ProcessGrouping.sections(for: groups, kinds: services)

		#expect(!sections[0].showsKind)
	}

	@Test("gives every section a distinct identity")
	func sectionsAreDistinct() {
		let groups = [
			ProjectGroup(name: "acme-mcp", stacks: [
				StackGroup(name: "ai", processes: [.init(name: "acme-mcp", status: .running)]),
			]),
			ProjectGroup(name: "acme-ai-chatbot", stacks: [
				StackGroup(name: "ai", processes: [.init(name: "chatbot", status: .running)]),
			]),
		]

		let ids = ProcessGrouping.sections(for: groups, kinds: [:]).map(\.id)

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
