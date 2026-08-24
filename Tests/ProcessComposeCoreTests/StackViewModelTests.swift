import Foundation
import Testing

@testable import ProcessComposeCore

@MainActor
struct StackViewModelTests {
	@Test("stops reporting a project once its server is gone")
	func forgetsTheProjectOnDisconnect() async {
		let client = StubClient(processes: [
			.init(name: "chatbot", namespace: "ai", status: .running, isRunning: true)
		])
		let viewModel = StackViewModel(client: client)

		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.project == nil)
		#expect(viewModel.uptime == nil)
	}

	@Test("lists every process the server reports")
	func listsProcessesFromInitialLoad() async {
		let client = StubClient(processes: [
			.init(name: "chatbot", namespace: "ai", status: .running, isRunning: true),
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: client)

		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.processes.map(\.name) == ["chatbot", "api"])
	}

	@Test("opens on the first project and shows only its processes")
	func showsOneProjectAtATime() async {
		let client = StubClient(processes: [
			.init(name: "chatbot", namespace: "ai", status: .running, isRunning: true),
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["chatbot": "acme-ai-chatbot", "api": "acme/api"]
		let viewModel = StackViewModel(client: client)

		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.projects.map(\.name) == ["acme", "acme-ai-chatbot"])
		#expect(viewModel.selectedProject == "acme")
		#expect(viewModel.visibleProcesses.map(\.name) == ["api"])
	}

	@Test("shows the other project's processes once it is selected")
	func switchesProject() async {
		let client = StubClient(processes: [
			.init(name: "chatbot", namespace: "ai", status: .running, isRunning: true),
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["chatbot": "acme-ai-chatbot", "api": "acme/api"]
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()
		viewModel.selection = "api"

		viewModel.select(project: "acme-ai-chatbot")

		#expect(viewModel.visibleProcesses.map(\.name) == ["chatbot"])
		#expect(viewModel.selection == nil)
	}

	@Test("keeps the project chosen before the connection when the stack still defines it")
	func keepsRestoredProject() async {
		let client = StubClient(processes: [
			.init(name: "chatbot", namespace: "ai", status: .running, isRunning: true),
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["chatbot": "acme-ai-chatbot", "api": "acme/api"]
		let viewModel = StackViewModel(client: client)
		viewModel.select(project: "acme-ai-chatbot")

		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.selectedProject == "acme-ai-chatbot")
	}

	@Test("falls back to the first project when the chosen one is gone")
	func fallsBackToFirstProject() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api"]
		let viewModel = StackViewModel(client: client)
		viewModel.select(project: "retired-repo")

		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.selectedProject == "acme")
	}

	@Test("gathers processes with no repo under one project")
	func gathersUngroupedProcesses() async {
		let client = StubClient(processes: [
			.init(name: "stray", namespace: "misc", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: client)

		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.selectedProject == "other")
		#expect(viewModel.visibleProcesses.map(\.name) == ["stray"])
	}

	@Test("applies a live state change from the event stream")
	func appliesLiveStateChange() async {
		let client = StubClient(processes: [
			.init(name: "relay", namespace: "relay", status: .disabled),
		])
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		client.emit(.init(
			state: .init(name: "relay", namespace: "relay", status: .running, isRunning: true)
		))
		client.finishStream()
		await session.value

		#expect(viewModel.processes.first?.status == .running)
		#expect(viewModel.processes.first?.isRunning == true)
	}

	@Test("reports the port when no server answers")
	func reportsUnreachableServer() async {
		let client = StubClient(loadFailure: ProcessComposeError.unreachable(port: 28080))
		let viewModel = StackViewModel(client: client)

		await viewModel.observe()

		#expect(viewModel.connection == .disconnected(reason: "No process-compose server on port 28080"))
	}

	@Test("names the process that failed to start")
	func surfacesStartFailure() async {
		let client = StubClient(processes: [.init(name: "relay", status: .disabled)])
		client.actionFailure = ProcessComposeError.server(message: "no such process: relay")
		let viewModel = StackViewModel(client: client)

		await viewModel.startProcess("relay")

		#expect(viewModel.lastError == "relay: no such process: relay")
		#expect(!viewModel.isBusy("relay"))
	}

	@Test("clears the previous error once an action succeeds")
	func clearsErrorAfterSuccess() async {
		let client = StubClient(processes: [.init(name: "relay", status: .disabled)])
		client.actionFailure = ProcessComposeError.server(message: "boom")
		let viewModel = StackViewModel(client: client)

		await viewModel.startProcess("relay")
		client.actionFailure = nil
		await viewModel.startProcess("relay")

		#expect(viewModel.lastError == nil)
	}

	@Test("selects no process on connect, so nothing streams until it is asked for")
	func selectsNoProcessOnConnect() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "web", namespace: "web", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: client)

		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.selection == nil)
		#expect(viewModel.selectedProcess == nil)
	}

	@Test("drops the selection when the server stops reporting that process")
	func dropsSelectionOnVanishedProcess() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()
		viewModel.selection = "api"

		let replacement = StubClient(processes: [
			.init(name: "web", namespace: "web", status: .running, isRunning: true),
		])
		replacement.finishStream()
		viewModel.use(replacement)

		// use() starts its own observation; driving one by hand as well would just
		// supersede it, so wait for the one it started.
		for _ in 0 ..< 1000 where viewModel.selection == "api" {
			await Task.yield()
		}

		#expect(viewModel.selection == nil)
	}

	@Test("keeps a selection the server still reports")
	func keepsLiveSelection() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "web", namespace: "web", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()
		viewModel.selection = "web"

		await viewModel.observe()

		#expect(viewModel.selection == "web")
	}

	@Test("starts every process the stack defines")
	func startsTheWholeStack() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed),
			.init(name: "worker", namespace: "api", status: .completed),
		])
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		await viewModel.startStack()

		#expect(client.started == ["api", "worker"])
		#expect(viewModel.lastError == nil)
	}

	@Test("leaves a process the config disabled switched off")
	func skipsDisabledProcesses() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed),
			.init(name: "houston-api", namespace: "houston", status: .disabled),
		])
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		await viewModel.startStack()

		#expect(client.started == ["api"])
	}

	@Test("stops every running process and leaves the stopped ones alone")
	func stopsTheWholeStack() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .completed),
		])
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		await viewModel.stopStack()

		#expect(client.stopped == ["api"])
	}

	@Test("names the processes that refused to start")
	func reportsProcessesThatRefusedToStart() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed),
			.init(name: "worker", namespace: "api", status: .completed),
		])
		client.refusingProcesses = ["worker"]
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		await viewModel.startStack()

		#expect(client.started == ["api", "worker"])
		#expect(viewModel.lastError == "Could not start worker")
	}

	@Test("offers to start the stack when every process is stopped")
	func offersToStartWhenIdle() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed),
		])
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.power == .canStart)
	}

	@Test("offers to stop the stack while a process runs")
	func offersToStopWhileRunning() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .completed),
		])
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.power == .canStop)
	}

	@Test("refuses to power the stack while the server is unreachable")
	func refusesPowerWhenDisconnected() async {
		let client = StubClient(loadFailure: ProcessComposeError.unreachable(port: 28080))
		let viewModel = StackViewModel(client: client)

		await viewModel.observe()

		#expect(!viewModel.canChangePower)
	}

	@Test("offers no action for a process it does not know")
	func offersNoActionForUnknownProcess() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		#expect(!viewModel.canStart("ghost"))
		#expect(!viewModel.canStop(nil))
	}

	@Test("offers start for a stopped process and stop for a running one")
	func offersTheActionThatFitsTheProcess() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .completed),
		])
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.canStop("api"))
		#expect(!viewModel.canStart("api"))
		#expect(viewModel.canStart("worker"))
		#expect(!viewModel.canStop("worker"))
	}

	@Test("says how far a stop reaches when other projects are running too")
	func namesEveryProjectAStopReaches() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "chatbot", namespace: "ai", status: .running, isRunning: true),
		])
		client.workingDirs = ["chatbot": "acme-ai-chatbot", "api": "acme/api"]
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.stopStackQuestion == "Stop 2 running processes across 2 projects?")
	}

	@Test("asks about the processes alone when one project has all of them")
	func asksAboutOneProject() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api"]
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.stopStackQuestion == "Stop 1 running process?")
	}

	@Test("offers nothing when no processes are known")
	func offersNothingWhenDisconnected() async {
		let client = StubClient(loadFailure: ProcessComposeError.unreachable(port: 28080))
		let viewModel = StackViewModel(client: client)

		await viewModel.observe()

		#expect(viewModel.power == .unavailable)
	}
}

struct ProcessStateTests {
	@Test("a process that exited non-zero reads as failed")
	func nonZeroExitIsFailure() {
		let state = ProcessState(name: "migrate", status: .completed, exitCode: 1)

		#expect(state.indicator == .failed)
	}

	@Test("a clean one-shot reads as idle, not failed")
	func cleanExitIsIdle() {
		let state = ProcessState(name: "acme-docker", status: .completed, exitCode: 0)

		#expect(state.indicator == .idle)
	}

	@Test("a running process with an unsatisfied probe still reads as waiting")
	func unreadyProbeIsWaiting() {
		let state = ProcessState(
			name: "chatbot",
			status: .running,
			readiness: "Not Ready",
			hasReadinessProbe: true,
			isRunning: true
		)

		#expect(state.indicator == .waiting)
	}

	@Test("a disabled process offers start and not stop")
	func disabledProcessCanOnlyStart() {
		let state = ProcessState(name: "relay", status: .disabled)

		#expect(state.canStart)
		#expect(!state.canStop)
	}

	@Test("counts a process the server calls Running as running, whatever the flag says")
	func trustsTheStatusOverTheRunningFlag() throws {
		let json = """
		{"name":"beta","namespace":"default","status":"Running","is_running":false}
		""".data(using: .utf8)!

		let state = try JSONDecoder().decode(ProcessState.self, from: json)

		#expect(state.isRunning)
		#expect(state.canStop)
	}

	@Test("decodes the server's process payload")
	func decodesServerPayload() throws {
		let json = """
		{"name":"api","namespace":"api","status":"Running","is_ready":"Ready",
		"has_ready_probe":true,"restarts":0,"exit_code":0,"pid":69794,
		"mem":34226176,"cpu":0.5,"is_running":true,"age":194399630583}
		""".data(using: .utf8)!

		let state = try JSONDecoder().decode(ProcessState.self, from: json)

		#expect(state.name == "api")
		#expect(state.status == .running)
		#expect(state.isReady)
		#expect(state.age == .nanoseconds(194_399_630_583))
	}
}

final class StubClient: ProcessComposeClient, @unchecked Sendable {
	nonisolated(unsafe) var actionFailure: (any Error)?
	nonisolated(unsafe) var refusingProcesses: Set<String> = []
	nonisolated(unsafe) var started: [String] = []
	nonisolated(unsafe) var stopped: [String] = []

	nonisolated(unsafe) var workingDirs: [String: String] = [:]
	nonisolated(unsafe) var logStreamFailure: (any Error)?
	nonisolated(unsafe) var truncated: [String] = []

	private let loadResult: Result<[ProcessState], any Error>
	private let stream: AsyncThrowingStream<ProcessStateEvent, any Error>
	private let continuation: AsyncThrowingStream<ProcessStateEvent, any Error>.Continuation
	private let logStream: AsyncThrowingStream<LogMessage, any Error>
	private let logContinuation: AsyncThrowingStream<LogMessage, any Error>.Continuation

	init(processes: [ProcessState] = [], loadFailure: (any Error)? = nil) {
		loadResult = loadFailure.map { .failure($0) } ?? .success(processes)
		(stream, continuation) = AsyncThrowingStream.makeStream()
		(logStream, logContinuation) = AsyncThrowingStream.makeStream()
	}

	func emit(_ event: ProcessStateEvent) { continuation.yield(event) }
	func finishStream() { continuation.finish() }

	func processes() async throws -> [ProcessState] { try loadResult.get() }

	func configuration(for name: String) async throws -> ProcessConfiguration {
		ProcessConfiguration(workingDir: workingDirs[name])
	}

	/// Lets a test hold a connection inside its setup phase.
	nonisolated(unsafe) var beforeProjectState: (() async -> Void)?

	func projectState() async throws -> ProjectState {
		await beforeProjectState?()

		return ProjectState(
			projectName: "test",
			version: "v1.122.0",
			processNum: 0,
			runningProcessNum: 0,
			upTimeNanoseconds: 0,
			configFiles: ["/tmp/process-compose.yaml"]
		)
	}

	func start(_ name: String) async throws {
		started.append(name)
		try failIfConfigured(name)
	}

	func stop(_ name: String) async throws {
		stopped.append(name)
		try failIfConfigured(name)
	}

	func restart(_ name: String) async throws { try failIfConfigured() }

	func stateEvents() -> AsyncThrowingStream<ProcessStateEvent, any Error> { stream }

	func logMessages(for name: String, backfill: Int) -> AsyncThrowingStream<LogMessage, any Error> {
		if let logStreamFailure {
			return AsyncThrowingStream { $0.finish(throwing: logStreamFailure) }
		}
		return logStream
	}

	func truncateLogs(for name: String) async throws {
		truncated.append(name)
		try failIfConfigured()
	}

	func emitLog(_ message: LogMessage) { logContinuation.yield(message) }
	func finishLogStream() { logContinuation.finish() }

	private func failIfConfigured(_ name: String? = nil) throws {
		if let name, refusingProcesses.contains(name) {
			throw ProcessComposeError.server(message: "no such process: \(name)")
		}
		if let actionFailure { throw actionFailure }
	}
}
