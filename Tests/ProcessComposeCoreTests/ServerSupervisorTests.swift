import Foundation
import Testing

@testable import ProcessComposeCore

@MainActor
struct ServerSupervisorTests {
	@Test("attaches to a server someone else started")
	func attachesToAForeignServer() async {
		let runner = FakeRunner()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(true),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .running(owned: false))
		#expect(runner.launched.isEmpty)
	}

	@Test("takes back the server an earlier run left behind")
	func adoptsRecordedServer() async {
		let runner = FakeRunner()
		let orphan = FakeServerProcess(pid: 4242)
		runner.adoptable[4242] = orphan
		let records = MemoryRecordStore(record: ServerRecord(pid: 4242, port: ServerAddress.defaultPort))
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(true),
			records: records
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .running(owned: true))

		await supervisor.stop()

		#expect(orphan.didTerminate)
		#expect(records.record == nil)
	}

	@Test("starts the configured server when nothing answers the port")
	func launchesWhenPortIsDead() async {
		let runner = FakeRunner()
		let records = MemoryRecordStore()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .running(owned: true))
		#expect(runner.launched == [.test])
		#expect(records.record == ServerRecord(pid: 4242, port: 28080))
	}

	@Test("stays put when no launch is configured")
	func staysIdleWithoutAPlan() async {
		let runner = FakeRunner()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: nil)

		#expect(supervisor.state == .unconfigured)
		#expect(runner.launched.isEmpty)
	}

	@Test("says why the server would not start")
	func reportsLaunchFailure() async {
		let runner = FakeRunner()
		runner.failure = TestError.noBinary
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .failed(reason: TestError.noBinary.localizedDescription))
		#expect(supervisor.canStart)
	}

	@Test("stops the server it started and forgets it")
	func stopsItsOwnServer() async {
		let runner = FakeRunner()
		let records = MemoryRecordStore()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.stop()

		#expect(runner.started?.didTerminate == true)
		#expect(runner.started?.didKill == false)
		#expect(supervisor.state == .idle)
		#expect(records.record == nil)
	}

	@Test("kills a server that ignores the request to stop")
	func killsAStubbornServer() async {
		let runner = FakeRunner()
		runner.ignoresTerminate = true
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore(),
			grace: .milliseconds(100)
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.stop()

		#expect(runner.started?.didKill == true)
		#expect(supervisor.state == .idle)
	}

	@Test("takes its server down as the app quits")
	func stopsOnQuit() async {
		let runner = FakeRunner()
		let records = MemoryRecordStore()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records
		)

		await supervisor.use(address: .standard, plan: .test)
		supervisor.stopOnQuit()

		#expect(runner.started?.didTerminate == true)
		#expect(records.record == nil)
	}

	@Test("starts nothing for inputs the user has already replaced")
	func ignoresACancelledProbe() async {
		let runner = FakeRunner()
		let probe = SlowReachability()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: probe,
			records: MemoryRecordStore()
		)

		let probing = Task { await supervisor.use(address: .standard, plan: .test) }
		await until { probe.didStart }
		probing.cancel()
		await probing.value

		#expect(runner.launched.isEmpty)
	}

	@Test("offers to start again once a server it attached to is gone")
	func rechecksAForeignServer() async {
		let runner = FakeRunner()
		let reachability = FakeReachability(true)
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: reachability,
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)
		reachability.isReachable = false
		await supervisor.recheck()

		#expect(supervisor.state == .idle)
		#expect(supervisor.canStart)
	}

	@Test("says what is wrong with the config instead of starting it")
	func refusesAConfigThatWillNotLoad() async {
		let runner = FakeRunner()
		runner.validation = .failed(reason: "watch path 'acme/v3' does not exist")
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .failed(reason: "watch path 'acme/v3' does not exist"))
		#expect(runner.launched.isEmpty)
	}

	@Test("shows what the server prints")
	func collectsServerOutput() async {
		let runner = FakeRunner()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)
		runner.started?.emit("chatbot is running")
		await until { supervisor.log.lines.count == 1 }

		#expect(supervisor.log.lines.first?.text == "chatbot is running")
	}
}

/// Spins the main actor until the watch task has caught up.
@MainActor
private func until(_ condition: () -> Bool, attempts: Int = 1000) async {
	for _ in 0 ..< attempts where !condition() {
		await Task.yield()
	}
}

private enum TestError: LocalizedError {
	case noBinary

	var errorDescription: String? { "No process-compose binary there" }
}

extension ServerLaunchPlan {
	fileprivate static let test = ServerLaunchPlan(
		executablePath: "/opt/homebrew/bin/process-compose",
		configurationPath: "/Users/dev/stack/process-compose.yaml",
		port: 28080
	)!
}

private final class FakeReachability: ServerReachability, @unchecked Sendable {
	var isReachable: Bool

	init(_ isReachable: Bool) {
		self.isReachable = isReachable
	}

	func isReachable(_ address: ServerAddress) async -> Bool { isReachable }
}

/// Stands in for a probe still waiting on the network when its inputs change.
private final class SlowReachability: ServerReachability, @unchecked Sendable {
	private(set) var didStart = false

	func isReachable(_ address: ServerAddress) async -> Bool {
		didStart = true
		try? await Task.sleep(for: .seconds(30))
		return false
	}
}

@MainActor
private final class FakeRunner: ServerRunner {
	var launched: [ServerLaunchPlan] = []
	var adoptable: [Int32: FakeServerProcess] = [:]
	var failure: (any Error)?
	var validation: ServerValidation = .valid
	var ignoresTerminate = false
	private(set) var started: FakeServerProcess?

	func run(_ plan: ServerLaunchPlan) throws -> any ServerProcess {
		if let failure { throw failure }

		launched.append(plan)

		let process = FakeServerProcess(pid: 4242, ignoresTerminate: ignoresTerminate)
		started = process

		return process
	}

	func validate(_ plan: ServerLaunchPlan) async -> ServerValidation {
		validation
	}

	func adopt(pid: Int32) -> (any ServerProcess)? {
		adoptable[pid]
	}
}

@MainActor
private final class FakeServerProcess: ServerProcess {
	let pid: Int32
	let output: AsyncStream<String>

	private(set) var isRunning = true
	private(set) var didTerminate = false
	private(set) var didKill = false

	private let feed: AsyncStream<String>.Continuation
	private let ignoresTerminate: Bool

	init(pid: Int32, ignoresTerminate: Bool = false) {
		let (lines, feed) = AsyncStream<String>.makeStream()

		self.pid = pid
		self.output = lines
		self.feed = feed
		self.ignoresTerminate = ignoresTerminate
	}

	func emit(_ line: String) {
		feed.yield(line)
	}

	func exitCode() async -> Int32 {
		while isRunning {
			try? await Task.sleep(for: .milliseconds(1))
		}
		return 0
	}

	func terminate() {
		didTerminate = true
		guard !ignoresTerminate else { return }
		stop()
	}

	func kill() {
		didKill = true
		stop()
	}

	private func stop() {
		isRunning = false
		feed.finish()
	}
}

private final class MemoryRecordStore: ServerRecordStore, @unchecked Sendable {
	private(set) var record: ServerRecord?

	init(record: ServerRecord? = nil) {
		self.record = record
	}

	func load() -> ServerRecord? { record }

	func save(_ record: ServerRecord) throws { self.record = record }

	func clear() throws { record = nil }
}
