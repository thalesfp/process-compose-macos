import Foundation
import Testing

@testable import ProcessComposeCore

@MainActor
struct HostileSettingsTests {
	@Test("survives a buffer size the settings field lets the user type")
	func survivesANegativeBufferSize() async {
		let client = StubClient()
		let viewModel = LogViewModel(client: client, maxLines: -1)
		viewModel.select("chatbot")

		let session = Task { await viewModel.stream() }
		client.emitLog(.init(message: "still here", processName: "chatbot"))
		client.finishLogStream()
		await session.value

		#expect(viewModel.lines.map(\.text) == ["still here"])
	}

	@Test("survives the buffer size being lowered past zero while lines are held")
	func survivesLoweringTheBufferPastZero() async {
		let client = StubClient()
		let viewModel = LogViewModel(client: client)
		viewModel.select("chatbot")

		let session = Task { await viewModel.stream() }
		client.emitLog(.init(message: "one", processName: "chatbot"))
		client.emitLog(.init(message: "two", processName: "chatbot"))
		client.finishLogStream()
		await session.value

		viewModel.maxLines = -5

		#expect(viewModel.lines.map(\.text) == ["two"])
	}

	@Test("refuses an address rather than pointing at a server the user did not ask for")
	func refusesAnUnusableAddress() {
		#expect(ServerAddress(host: "local host", port: 28080) == nil)
		#expect(ServerAddress(host: "  ", port: 28080) == nil)
		#expect(ServerAddress(host: "localhost", port: -1) == nil)
		#expect(ServerAddress(host: "localhost", port: 0) == nil)
		#expect(ServerAddress(host: "localhost", port: 999_999) == nil)
	}

	@Test("keeps a usable address as typed")
	func keepsAUsableAddress() throws {
		let address = try #require(ServerAddress(host: " example.local ", port: 9000))

		#expect(address.host == "example.local")
		#expect(address.port == 9000)
	}

	@Test("builds a request URL from an address it accepted")
	func buildsAURLFromAnAcceptedAddress() throws {
		let address = try #require(ServerAddress(host: "example.local", port: 9000))

		#expect(address.url(path: "/processes").absoluteString == "http://example.local:9000/processes")
	}

	@Test("does not offer start for a process the server has already scheduled")
	func refusesStartForScheduledProcesses() {
		for status in [ProcessStatus.pending, .restarting, .terminating, .watching] {
			#expect(!ProcessState(name: "api", status: status).canStart)
		}
	}

	@Test("offers start for a process that has finished or never ran")
	func offersStartForFinishedProcesses() {
		for status in [ProcessStatus.completed, .skipped, .disabled, .error] {
			#expect(ProcessState(name: "api", status: status).canStart)
		}
	}
}

@MainActor
struct StackSummaryTests {
	@Test("counts running processes from live state, not the connection snapshot")
	func countsFromLiveState() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .completed),
		])
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.project?.runningProcessNum == 0)
		#expect(viewModel.runningCount == 1)
		#expect(viewModel.processCount == 2)
	}

	@Test("republishes the uptime as the clock moves, so the subtitle redraws")
	func uptimeAdvancesWithTheClock() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		let clock = MovableClock()
		let viewModel = StackViewModel(client: client, now: { clock.now })
		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.uptime == .seconds(0))

		clock.now = Date(timeIntervalSince1970: 60)
		viewModel.refreshUptime()

		#expect(viewModel.uptime == .seconds(60))
	}

	@Test("leaves the old server alone once the log pane is released")
	func releasedLogPaneLeavesTheOldServerAlone() async {
		let client = StubClient()
		let viewModel = LogViewModel(client: client)
		viewModel.select("chatbot")

		let session = Task { await viewModel.stream() }
		client.emitLog(.init(message: "listening", processName: "chatbot"))
		client.finishLogStream()
		await session.value

		viewModel.select(nil)
		await viewModel.clear()

		#expect(viewModel.selected == nil)
		#expect(viewModel.lines.isEmpty)
		#expect(client.truncated.isEmpty)
	}

	@Test("keeps the settings error when a live stream is cancelled underneath it")
	func refusedAddressSurvivesStreamCancellation() async {
		let reason = "Settings has no usable server address for local host:0"
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: client)
		viewModel.use(client)

		for _ in 0 ..< 1000 where viewModel.connection != .connected {
			await Task.yield()
		}

		viewModel.refuseAddress(reason)
		for _ in 0 ..< 200 {
			await Task.yield()
		}

		#expect(viewModel.connection == .disconnected(reason: reason))
	}

	@Test("a connection superseded during setup cannot publish over a refused address")
	func supersededSetupCannotPublish() async {
		let reason = "Settings has no usable server address for local host:0"
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.finishStream()
		let gate = Gate()
		client.beforeProjectState = { await gate.enter() }

		let viewModel = StackViewModel(client: client)
		let session = Task { await viewModel.observe() }
		for _ in 0 ..< 1000 where !gate.isHolding {
			await Task.yield()
		}

		viewModel.refuseAddress(reason)
		gate.open()
		await session.value

		#expect(viewModel.connection == .disconnected(reason: reason))
		#expect(viewModel.processes.isEmpty)
	}

	@Test("stops offering a stack when the settings address is refused")
	func refusedAddressLeavesNothingConnected() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		viewModel.refuseAddress("Settings has no usable server address for local host:0")

		#expect(viewModel.connection == .disconnected(reason: "Settings has no usable server address for local host:0"))
		#expect(viewModel.processes.isEmpty)
		#expect(viewModel.uptime == nil)
		#expect(viewModel.selection == nil)
		#expect(!viewModel.canChangePower)
	}
}

/// A clock the test moves by hand, since Date() cannot be rewound.
final class MovableClock: @unchecked Sendable {
	var now = Date(timeIntervalSince1970: 0)
}


/// Holds a caller inside an async call until the test lets it go.
final class Gate: @unchecked Sendable {
	private(set) var isHolding = false
	private var release: CheckedContinuation<Void, Never>?

	func enter() async {
		await withCheckedContinuation { continuation in
			release = continuation
			isHolding = true
		}
	}

	func open() {
		release?.resume()
		release = nil
		isHolding = false
	}
}
