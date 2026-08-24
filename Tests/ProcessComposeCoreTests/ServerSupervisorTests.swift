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
		let records = MemoryRecordStore(
			record: ServerRecord(group: 4242, port: ServerAddress.defaultPort, owner: .test(900))
		)
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(true),
			records: records,
			owner: .test(901)
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .running(owned: true))
		#expect(runner.adoptedWith.contains("process-compose"))

		await supervisor.stop()

		#expect(orphan.didTerminate)
		#expect(records.record == nil)
	}

	@Test("leaves the server another copy of the app is running")
	func leavesAnotherCopysServerAlone() async {
		let runner = FakeRunner()
		let orphan = FakeServerProcess(pid: 4242)
		runner.adoptable[4242] = orphan
		runner.liveOwners = [.test(900)]
		let records = MemoryRecordStore(
			record: ServerRecord(group: 4242, port: ServerAddress.defaultPort, owner: .test(900))
		)
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(true),
			records: records,
			owner: .test(901)
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .running(owned: false))

		await supervisor.stop()

		#expect(orphan.didTerminate == false)
		#expect(records.record != nil)
	}

	@Test("starts the configured server when nothing answers the port")
	func launchesWhenPortIsDead() async {
		let runner = FakeRunner()
		let records = MemoryRecordStore()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records,
			owner: .test(901)
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .running(owned: true))
		#expect(runner.launched == [.test])
		#expect(records.record == ServerRecord(group: 4242, port: 28080, owner: .test(901)))
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

	@Test("quitting a copy that started nothing leaves the record alone")
	func quitKeepsAnotherCopysRecord() async {
		let runner = FakeRunner()
		runner.liveOwners = [.test(900)]
		let record = ServerRecord(group: 4242, port: ServerAddress.defaultPort, owner: .test(900))
		let records = MemoryRecordStore(record: record)
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(true),
			records: records,
			owner: .test(901)
		)

		await supervisor.use(address: .standard, plan: .test)
		supervisor.stopOnQuit()

		#expect(records.record == record)
	}

	@Test("starts nothing when Settings points at another machine")
	func refusesToStartForARemoteAddress() async {
		let runner = FakeRunner()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)
		let remote = ServerAddress(host: "build-box.local", port: 28080)!

		await supervisor.use(address: remote, plan: .test)

		#expect(supervisor.state == .remote)
		#expect(runner.launched.isEmpty)
		#expect(supervisor.canStart == false)
	}

	@Test("does not take a server on another machine for its own")
	func doesNotAdoptARemoteServer() async {
		let runner = FakeRunner()
		runner.adoptable[4242] = FakeServerProcess(pid: 4242)
		let records = MemoryRecordStore(record: ServerRecord(group: 4242, port: 28080, owner: .test(901)))
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(true),
			records: records,
			owner: .test(901)
		)
		let remote = ServerAddress(host: "build-box.local", port: 28080)!

		await supervisor.use(address: remote, plan: .test)

		#expect(supervisor.state == .running(owned: false))
	}

	@Test("counts a port as a server only when it reports a project")
	func recognisesAProcessComposeServer() {
		let project = Data(
			#"{"projectName":"stack","version":"v1.122.0","processNum":1,"runningProcessNum":1,"upTime":1000,"fileNames":[]}"#
				.utf8
		)

		#expect(LiveServerReachability.answers(status: 200, body: project))
		#expect(LiveServerReachability.answers(status: 200, body: Data(#"{"error":"not found"}"#.utf8)) == false)
		#expect(LiveServerReachability.answers(status: 404, body: project) == false)
	}

	@Test("keeps the running server when its request was abandoned")
	func keepsTheServerWhenTheRequestIsCancelled() async {
		let runner = FakeRunner()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)

		let other = ServerAddress(host: "localhost", port: 28081)!
		let abandoned = Task { await supervisor.use(address: other, plan: .test) }
		abandoned.cancel()
		await abandoned.value

		#expect(runner.started?.isRunning == true)
		#expect(supervisor.state == .running(owned: true))
	}

	@Test("finishes stopping even when whoever asked has walked away")
	func stopsDespiteACancelledCaller() async {
		let runner = FakeRunner()
		let records = MemoryRecordStore()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records
		)

		await supervisor.use(address: .standard, plan: .test)

		let stopping = Task { await supervisor.stop() }
		stopping.cancel()
		await stopping.value

		#expect(runner.started?.didTerminate == true)
		#expect(supervisor.state == .idle)
		#expect(records.record == nil)
	}

	@Test("leaves the record of a server another copy won the port with")
	func doesNotClearAnotherCopysRecord() async {
		let runner = FakeRunner()
		let records = MemoryRecordStore()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records,
			owner: .test(901)
		)

		await supervisor.use(address: .standard, plan: .test)

		let winner = ServerRecord(group: 7777, port: 28080, owner: .test(902))
		try? records.save(winner)

		await supervisor.stop()

		#expect(records.record == winner)
	}

	@Test("takes back a recorded server that is up but not answering yet")
	func recoversARecordedServerThatIsNotAnsweringYet() async {
		let runner = FakeRunner()
		let recovered = FakeServerProcess(pid: 4242)
		runner.adoptable[4242] = recovered
		let records = MemoryRecordStore(record: ServerRecord(group: 4242, port: 28080, owner: .test(901)))
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records,
			owner: .test(901)
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .running(owned: true))
		#expect(runner.launched.isEmpty)
	}

	@Test("does not start a second server beside one another copy is running")
	func leavesAnUnreachableServerOfAnotherCopyAlone() async {
		let runner = FakeRunner()
		runner.liveOwners = [.test(900)]
		let record = ServerRecord(group: 4242, port: 28080, owner: .test(900))
		let records = MemoryRecordStore(record: record)
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records,
			owner: .test(901)
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .running(owned: false))
		#expect(runner.launched.isEmpty)
		#expect(records.record == record)
	}

	@Test("starts the stack once Settings comes back to this machine")
	func startsAfterSwitchingBackFromRemote() async {
		let runner = FakeRunner()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)
		let remote = ServerAddress(host: "build-box.local", port: 28080)!

		await supervisor.use(address: remote, plan: .test)

		#expect(supervisor.state == .remote)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .running(owned: true))
		#expect(runner.launched == [.test])
	}

	@Test("does not treat a recycled owner pid as the app that started a server")
	func refusesAnOwnerThatIsADifferentProcessNow() async {
		let runner = FakeRunner()
		runner.adoptable[4242] = FakeServerProcess(pid: 4242)
		// The pid is in use, but by something that is not the app that wrote the record.
		runner.liveOwners = [.test(900)]
		let records = MemoryRecordStore(
			record: ServerRecord(group: 4242, port: 28080, owner: ServerOwner(pid: 900, startedAt: 111))
		)
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records,
			owner: .test(901)
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .running(owned: true))
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

extension ServerOwner {
	fileprivate static func test(_ pid: Int32) -> ServerOwner {
		ServerOwner(pid: pid, startedAt: Int64(pid) * 1000)
	}
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
	var liveOwners: Set<ServerOwner> = []
	private(set) var adoptedWith: Set<String> = []
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

	func adopt(group: Int32, names: Set<String>) -> (any ServerProcess)? {
		adoptedWith = names

		return adoptable[group]
	}

	func isRunning(_ owner: ServerOwner) -> Bool {
		liveOwners.contains(owner)
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

	func claimLaunch() -> ServerLaunchClaim? { nil }

	func clear(_ record: ServerRecord) throws {
		guard self.record == record else { return }

		self.record = nil
	}
}
