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

	@Test("takes a new identity when it is pointed at another server")
	func changesIdentityWhenRepointed() async {
		let supervisor = ServerSupervisor(
			runner: FakeRunner(),
			reachability: FakeReachability(true),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)
		let first = supervisor.identity

		await supervisor.use(address: ServerAddress(host: "localhost", port: 28099), plan: .test)

		#expect(supervisor.identity != first)
	}

	@Test("stops nothing when the server it was asked about is no longer the one it holds")
	func refusesToStopAServerItWasNotAskedAbout() async {
		let runner = FakeRunner()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()
		let stale = supervisor.identity - 1

		await supervisor.stop(expecting: stale)

		#expect(supervisor.state == .running(owned: true))

		await supervisor.stop(expecting: supervisor.identity)

		#expect(supervisor.state != .running(owned: true))
	}

	@Test("keeps its identity when a second window asks for the same server")
	func keepsIdentityForTheSameServer() async {
		let supervisor = ServerSupervisor(
			runner: FakeRunner(),
			reachability: FakeReachability(true),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)
		let first = supervisor.identity

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.identity == first)
	}

	@Test("takes a new identity when the server behind it is replaced")
	func changesIdentityWhenTheServerIsReplaced() async {
		let runner = FakeRunner()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()
		let running = supervisor.identity

		// The server going is itself a change: `stop` does not bump the counter on its own,
		// so only tracking the concrete server catches this.
		await supervisor.stop()

		#expect(supervisor.identity != running)
	}

	@Test("takes back the server an earlier run left behind")
	func adoptsRecordedServer() async {
		let runner = FakeRunner()
		let orphan = FakeServerProcess(pid: 4242)
		runner.adoptable[4242] = orphan
		let records = MemoryRecordStore(
			record: ServerRecord(group: 4242, port: ServerAddress.defaultPort, owner: .test(900), members: [4242: [.test(4242)]])
		)
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(true),
			records: records,
			owner: .test(901)
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .running(owned: true))

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
			record: ServerRecord(group: 4242, port: ServerAddress.defaultPort, owner: .test(900), members: [4242: [.test(4242)]])
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

	@Test("waits to be asked before starting a server")
	func waitsToBeAskedWhenPortIsDead() async {
		let runner = FakeRunner()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .idle)
		#expect(runner.launched.isEmpty)
		#expect(supervisor.canStart)
	}

	@Test("starts the configured server when asked")
	func launchesWhenAsked() async {
		let runner = FakeRunner()
		let records = MemoryRecordStore()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records,
			owner: .test(901)
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()

		#expect(supervisor.state == .running(owned: true))
		#expect(runner.launched == [.test])
		#expect(records.record?.group == 4242)
		#expect(records.record?.owner == .test(901))
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
		await supervisor.start()

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
		await supervisor.start()
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
		await supervisor.start()
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
		await supervisor.start()
		supervisor.stopOnQuit()

		#expect(runner.started?.didTerminate == true)
		#expect(records.record == nil)
	}

	@Test("starts the config the user ended on, not one they replaced")
	func ignoresASupersededRequest() async {
		let runner = FakeRunner()
		let probe = SlowReachability()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: probe,
			records: MemoryRecordStore()
		)

		let first = Task { await supervisor.use(address: .standard, plan: .test) }
		await settle(until: { probe.didStart })

		// The settings move on while the first request is still looking at the port.
		probe.answerNow()
		await supervisor.use(address: .standard, plan: .other)
		await first.value
		await supervisor.start()

		#expect(runner.launched == [.other])
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
		reachability.presence = .nothing
		await supervisor.recheck()

		#expect(supervisor.state == .idle)
		#expect(supervisor.canStart)
	}

	@Test("attaches to a server started elsewhere while it waits to be asked")
	func attachesToAServerThatAppears() async {
		let runner = FakeRunner()
		let reachability = FakeReachability(false)
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: reachability,
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)
		reachability.presence = .processCompose
		await supervisor.attachIfAnswering()

		#expect(supervisor.state == .running(owned: false))
		#expect(runner.launched.isEmpty)
	}

	@Test("warns that moving a server it started stops it")
	func warnsThatMovingItsServerStopsIt() async {
		let supervisor = ServerSupervisor(
			runner: FakeRunner(),
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()

		#expect(supervisor.wouldStop(movingTo: ServerAddress(host: "localhost", port: 28099)))
		#expect(supervisor.wouldStop(movingTo: .standard) == false)
	}

	@Test("moving to an address it cannot use stops nothing")
	func anUnusableAddressStopsNothing() async {
		let supervisor = ServerSupervisor(
			runner: FakeRunner(),
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()

		#expect(supervisor.wouldStop(movingTo: nil) == false)
	}

	@Test("moving away from a server it only attached to stops nothing")
	func movingAwayFromAForeignServerStopsNothing() async {
		let supervisor = ServerSupervisor(
			runner: FakeRunner(),
			reachability: FakeReachability(true),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.wouldStop(movingTo: ServerAddress(host: "localhost", port: 28099)) == false)
	}

	@Test("says it is starting while a launch is under way")
	func reportsALaunchUnderWay() async {
		let runner = FakeRunner()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)
		var wasLaunchingDuringCheck = false
		runner.whileValidating = {
			wasLaunchingDuringCheck = MainActor.assumeIsolated { supervisor.isLaunching }
		}

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()

		#expect(wasLaunchingDuringCheck)
		#expect(supervisor.isLaunching == false)
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
		await supervisor.start()

		#expect(supervisor.state == .failed(reason: "watch path 'acme/v3' does not exist"))
		#expect(runner.launched.isEmpty)
	}

	@Test("quitting a copy that started nothing leaves the record alone")
	func quitKeepsAnotherCopysRecord() async {
		let runner = FakeRunner()
		runner.liveOwners = [.test(900)]
		let record = ServerRecord(group: 4242, port: ServerAddress.defaultPort, owner: .test(900), members: [4242: [.test(4242)]])
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

		#expect(LiveServerReachability.presence(status: 200, body: project) == .processCompose)
		#expect(LiveServerReachability.presence(status: 200, body: Data(#"{"error":"x"}"#.utf8)) == .occupied)
		// An authenticated server refuses without a token, and the port is still taken.
		#expect(LiveServerReachability.presence(status: 401, body: Data()) == .occupied)
		#expect(LiveServerReachability.presence(status: nil, body: Data()) == .nothing)
	}

	@Test("finishes moving to another address even when whoever asked has gone")
	func finishesAMoveItsCallerAbandoned() async {
		let runner = FakeRunner()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()

		let other = ServerAddress(host: "localhost", port: 28081)!
		let abandoned = Task { await supervisor.use(address: other, plan: .test) }
		abandoned.cancel()
		await abandoned.value

		#expect(runner.started?.didTerminate == true)
		#expect(supervisor.state == .idle)
		#expect(supervisor.canStart)
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
		await supervisor.start()

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
		await supervisor.start()

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
		let records = MemoryRecordStore(
			record: ServerRecord(group: 4242, port: 28080, owner: .test(901), members: [4242: [.test(4242)]])
		)
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
		let record = ServerRecord(group: 4242, port: 28080, owner: .test(900), members: [4242: [.test(4242)]])
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

	@Test("offers to start once Settings comes back to this machine")
	func offersToStartAfterSwitchingBackFromRemote() async {
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

		#expect(supervisor.state == .idle)
		#expect(supervisor.canStart)
		#expect(runner.launched.isEmpty)
	}

	@Test("does not treat a recycled owner pid as the app that started a server")
	func refusesAnOwnerThatIsADifferentProcessNow() async {
		let runner = FakeRunner()
		runner.adoptable[4242] = FakeServerProcess(pid: 4242)
		// The pid is in use, but by something that is not the app that wrote the record.
		runner.liveOwners = [.test(900)]
		let records = MemoryRecordStore(
			record: ServerRecord(group: 4242, port: 28080, owner: ServerOwner(pid: 900, startedAt: 111), members: [4242: [.test(4242)]])
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

	@Test("starts nothing it could not record")
	func refusesToStartWhatItCannotRecord() async {
		let runner = FakeRunner()
		let records = MemoryRecordStore()
		records.savingFails = true
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()

		#expect(runner.started?.didTerminate == true)
		#expect(supervisor.isOwned == false)
		if case .failed = supervisor.state {} else { Issue.record("expected a failure, got \(supervisor.state)") }
	}

	@Test("starts nothing while another copy holds the right to start")
	func refusesToStartWithoutTheClaim() async {
		let runner = FakeRunner()
		let records = MemoryRecordStore()
		records.refusesClaim = true
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()

		#expect(runner.launched.isEmpty)
		if case .failed = supervisor.state {} else { Issue.record("expected a failure, got \(supervisor.state)") }
	}

	@Test("writes itself into the record of a server it takes over")
	func writesItselfIntoAnAdoptedRecord() async {
		let runner = FakeRunner()
		runner.adoptable[4242] = FakeServerProcess(pid: 4242)
		let records = MemoryRecordStore(
			record: ServerRecord(group: 4242, port: 28080, owner: .test(900), members: [4242: [.test(4242)]])
		)
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(true),
			records: records,
			owner: .test(901)
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .running(owned: true))
		#expect(records.record?.owner == .test(901))
		#expect(records.record?.group == 4242)
	}

	@Test("leaves a stack alone once another copy has taken it over")
	func doesNotTakeOverTwice() async {
		let records = MemoryRecordStore(
			record: ServerRecord(group: 4242, port: 28080, owner: .test(900), members: [4242: [.test(4242)]])
		)

		let first = FakeRunner()
		first.adoptable[4242] = FakeServerProcess(pid: 4242)
		let firstCopy = ServerSupervisor(
			runner: first,
			reachability: FakeReachability(true),
			records: records,
			owner: .test(901)
		)

		await firstCopy.use(address: .standard, plan: .test)

		let second = FakeRunner()
		second.adoptable[4242] = FakeServerProcess(pid: 4242)
		second.liveOwners = [.test(901)]
		let secondCopy = ServerSupervisor(
			runner: second,
			reachability: FakeReachability(true),
			records: records,
			owner: .test(902)
		)

		await secondCopy.use(address: .standard, plan: .test)

		#expect(firstCopy.state == .running(owned: true))
		#expect(secondCopy.state == .running(owned: false))
		#expect(records.record?.owner == .test(901))
	}

	@Test("keeps the record of a stack that would not stop")
	func keepsTheRecordOfAStackItCouldNotStop() async {
		let runner = FakeRunner()
		runner.ignoresTerminate = true
		runner.ignoresKill = true
		let records = MemoryRecordStore()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records,
			grace: .milliseconds(100)
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()
		await supervisor.stop()

		#expect(records.record != nil)
		if case .failed = supervisor.state {} else { Issue.record("expected a failure, got \(supervisor.state)") }
	}

	@Test("starts nothing beside a recorded stack it cannot take over")
	func refusesToLaunchBesideARecordedStack() async {
		let runner = FakeRunner()
		// The group is alive, but nothing in it is recognised, so it cannot be adopted.
		runner.liveGroups = [4242]
		let record = ServerRecord(group: 4242, port: 28080, owner: .test(900), members: [4242: [.test(4242)]])
		let records = MemoryRecordStore(record: record)
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records,
			owner: .test(901)
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(runner.launched.isEmpty)
		#expect(records.record == record)
		if case .failed = supervisor.state {} else { Issue.record("expected a failure, got \(supervisor.state)") }
	}

	@Test("starts nothing where something else is already answering")
	func refusesAnOccupiedPort() async {
		let runner = FakeRunner()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(.occupied),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(runner.launched.isEmpty)
		if case .failed = supervisor.state {} else { Issue.record("expected a failure, got \(supervisor.state)") }
	}

	@Test("starts nothing when the port is taken while the config is being checked")
	func refusesAPortTakenDuringValidation() async {
		let runner = FakeRunner()
		let reachability = FakeReachability(.nothing)
		// Something binds the port while the check runs.
		runner.whileValidating = { reachability.presence = .occupied }
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: reachability,
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()

		#expect(runner.launched.isEmpty)
		if case .failed = supervisor.state {} else { Issue.record("expected a failure, got \(supervisor.state)") }
	}

	@Test("does not take over a group whose number has been handed to someone else")
	func refusesAGroupThatIsNoLongerTheRecordedOne() async {
		let runner = FakeRunner()
		// The group number is in use, but by processes this stack was never recorded holding.
		runner.adoptable[4242] = FakeServerProcess(pid: 4242)
		let record = ServerRecord(
			group: 4242,
			port: 28080,
			owner: .test(900),
			members: [4242: [ServerOwner(pid: 4242, startedAt: 11)]]
		)
		let records = MemoryRecordStore(record: record)
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(true),
			records: records,
			owner: .test(901)
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .running(owned: false))
		#expect(records.record == record)
	}

	@Test("does not take a group back on the strength of a service that left it")
	func refusesAGroupWhoseSurvivorMovedOn() async {
		let runner = FakeRunner()
		runner.adoptable[4242] = FakeServerProcess(pid: 4242)
		// The service is alive and is exactly what was recorded, but it is recorded under a
		// group of its own, and says nothing about who holds 4242 now.
		let service = ServerOwner(pid: 5555, startedAt: Int64(5555))
		let record = ServerRecord(
			group: 4242,
			port: 28080,
			owner: .test(900),
			members: [5555: [service]]
		)
		let records = MemoryRecordStore(record: record)
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(true),
			records: records,
			owner: .test(901)
		)

		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .running(owned: false))
		#expect(records.record == record)
	}

	@Test("still takes down a server it could not record when the app quits at once")
	func stopsAnUnrecordedServerOnQuit() async {
		let runner = FakeRunner()
		// Ignores the request to stop, so the quit has to force it.
		runner.ignoresTerminate = true
		let records = MemoryRecordStore()
		records.savingFails = true
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records,
			grace: .milliseconds(50)
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()

		// The record failed and the stack would not stop, so it is still the app's to stop.
		supervisor.stopOnQuit()

		#expect(runner.started?.didTerminate == true)
		#expect(runner.started?.didKill == true)
	}

	@Test("does not let a finished shutdown retire the server that replaced it")
	func aFinishedShutdownLeavesTheReplacementAlone() async {
		let runner = FakeRunner()
		runner.ignoresTerminate = true
		let records = MemoryRecordStore()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records,
			grace: .milliseconds(100)
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()

		let first = runner.started

		// Away to another port and back again while the first is still stopping.
		let other = ServerAddress(host: "localhost", port: 28081)!
		await supervisor.use(address: other, plan: .test)
		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()

		#expect(supervisor.state == .running(owned: true))
		#expect(records.record != nil)
		#expect(runner.started !== first)
	}

	@Test("asking again for what is already running starts nothing more")
	func joinsARequestAlreadyUnderWay() async {
		let runner = FakeRunner()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()

		let started = runner.started

		// A second window, or the same one rebuilt, asking for exactly the same thing.
		await supervisor.use(address: .standard, plan: .test)

		#expect(runner.launched.count == 1)
		#expect(runner.started === started)
		#expect(supervisor.state == .running(owned: true))
	}

	@Test("an identity that cannot be read is never taken for a running process")
	func unreadableIdentityIsNeverRunning() {
		#expect(ServerOwner(pid: ProcessInfo.processInfo.processIdentifier, startedAt: 0).isRunning == false)
		#expect(ServerOwner.current.isRunning)
	}

	@Test("starts a server when the recorded group number now belongs to someone else")
	func launchesWhenTheRecordedStackIsGone() async {
		let runner = FakeRunner()
		// The number is in use, but by nothing this stack was recorded as holding, so the
		// recorded stack is gone and the port is free.
		let records = MemoryRecordStore(
			record: ServerRecord(
				group: 4242,
				port: 28080,
				owner: .test(900),
				members: [4242: [ServerOwner(pid: 4242, startedAt: 11)]]
			)
		)
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: records,
			owner: .test(901)
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()

		#expect(supervisor.state == .running(owned: true))
		#expect(runner.launched == [.test])
	}

	@Test("settles a request even when a second window asking the same goes away")
	func settlesARequestItsSecondCallerAbandoned() async {
		let runner = FakeRunner()
		let probe = SlowReachability()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: probe,
			records: MemoryRecordStore()
		)

		// Two windows asking for the same thing; the second goes away mid-probe.
		let first = Task { await supervisor.use(address: .standard, plan: .test) }
		await settle(until: { probe.didStart })
		let second = Task { await supervisor.use(address: .standard, plan: .test) }
		second.cancel()

		probe.answerNow()
		await first.value
		await second.value

		#expect(supervisor.state == .idle)
		#expect(supervisor.canStart)
	}

	@Test("finishes a launch even when whoever asked for it has gone")
	func finishesALaunchItsCallerAbandoned() async {
		let runner = FakeRunner()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)

		let starting = Task { await supervisor.start() }
		starting.cancel()
		await starting.value

		#expect(runner.launched == [.test])
		#expect(supervisor.state == .running(owned: true))
	}

	@Test("does not let a finished request clear the slot of a later one")
	func anEarlierRequestLeavesTheCurrentSlotAlone() async {
		let runner = FakeRunner()
		let probe = SlowReachability()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: probe,
			records: MemoryRecordStore()
		)

		let first = Task { await supervisor.use(address: .standard, plan: .test) }
		await settle(until: { probe.didStart })

		let other = ServerAddress(host: "localhost", port: 28081)!
		let second = Task { await supervisor.use(address: other, plan: .test) }
		let third = Task { await supervisor.use(address: .standard, plan: .test) }

		probe.answerNow()
		await first.value
		await second.value
		await third.value
		await supervisor.start()

		// The third request is the one that counts, and starting runs exactly one server.
		#expect(runner.launched == [.test])
		#expect(supervisor.state == .running(owned: true))
	}

	@Test("keeps a running server of its own through a port that answers strangely")
	func keepsItsServerThroughAnOddAnswer() async {
		let runner = FakeRunner()
		let reachability = FakeReachability(.nothing)
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: reachability,
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()

		// The stack is up but answering oddly for a moment, as one does while it starts.
		reachability.presence = .occupied
		await supervisor.use(address: .standard, plan: .test)

		#expect(supervisor.state == .running(owned: true))
		#expect(supervisor.isOwned)
	}

	@Test("stopping a server on purpose is not a failure, whatever the signal made of it")
	func aDeliberateStopIsNotAFailure() async {
		let runner = FakeRunner()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()
		runner.started?.exitStatus = -1

		await supervisor.stop()
		await settle(until: { supervisor.state == .idle })

		#expect(supervisor.state == .idle)
	}

	@Test("a typed address the app cannot use does not stop the running stack")
	func keepsTheStackThroughAnUnusableAddress() async {
		let runner = FakeRunner()
		let supervisor = ServerSupervisor(
			runner: runner,
			reachability: FakeReachability(false),
			records: MemoryRecordStore()
		)

		await supervisor.use(address: .standard, plan: .test)
		await supervisor.start()

		let started = runner.started

		await supervisor.use(address: nil, plan: .test)

		#expect(started?.didTerminate == false)
		#expect(supervisor.state == .unconfigured)

		// And the stack is still there to come back to.
		await supervisor.use(address: .standard, plan: .test)

		#expect(runner.launched.count == 1)
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
		await supervisor.start()
		runner.started?.emit("chatbot is running")
		await settle(until: { supervisor.log.lines.count == 1 })

		#expect(supervisor.log.lines.first?.text == "chatbot is running")
	}
}

private enum TestError: LocalizedError {
	case noBinary

	var errorDescription: String? { "No process-compose binary there" }
}

extension ServerOwner {
	fileprivate static func test(_ pid: Int32) -> ServerOwner {
		ServerOwner(pid: pid, startedAt: Int64(pid))
	}
}

extension ServerLaunchPlan {
	fileprivate static let other = ServerLaunchPlan(
		executablePath: "/opt/homebrew/bin/process-compose",
		configurationPath: "/Users/dev/other/process-compose.yaml",
		port: 28080
	)!

	fileprivate static let test = ServerLaunchPlan(
		executablePath: "/opt/homebrew/bin/process-compose",
		configurationPath: "/Users/dev/stack/process-compose.yaml",
		port: 28080
	)!
}

private final class FakeReachability: ServerReachability, @unchecked Sendable {
	var presence: ServerPresence

	init(_ presence: ServerPresence) {
		self.presence = presence
	}

	convenience init(_ isReachable: Bool) {
		self.init(isReachable ? .processCompose : .nothing)
	}

	func look(at address: ServerAddress) async -> ServerPresence { presence }
}

/// Stands in for a probe still waiting on the network when its inputs change.
private final class SlowReachability: ServerReachability, @unchecked Sendable {
	private let lock = NSLock()
	private var started = false
	private var released = false

	var didStart: Bool {
		lock.lock()
		defer { lock.unlock() }
		return started
	}

	func answerNow() {
		lock.lock()
		released = true
		lock.unlock()
	}

	func look(at address: ServerAddress) async -> ServerPresence {
		begin()

		while !isReleased {
			try? await Task.sleep(for: .milliseconds(10))
		}

		return .nothing
	}

	private var isReleased: Bool {
		lock.lock()
		defer { lock.unlock() }
		return released
	}

	private func begin() {
		lock.lock()
		started = true
		lock.unlock()
	}
}

@MainActor
private final class FakeRunner: ServerRunner {
	var launched: [ServerLaunchPlan] = []
	var adoptable: [Int32: FakeServerProcess] = [:]
	var failure: (any Error)?
	var validation: ServerValidation = .valid
	var liveOwners: Set<ServerOwner> = []
	var liveGroups: Set<Int32> = []
	private(set) var adoptedWith: Set<ServerOwner> = []
	var ignoresTerminate = false
	var ignoresKill = false
	private(set) var started: FakeServerProcess?

	func run(_ plan: ServerLaunchPlan) throws -> any ServerProcess {
		if let failure { throw failure }

		launched.append(plan)

		let process = FakeServerProcess(
			pid: 4242,
			ignoresTerminate: ignoresTerminate,
			ignoresKill: ignoresKill
		)
		started = process

		return process
	}

	nonisolated(unsafe) var whileValidating: (() -> Void)?

	func validate(_ plan: ServerLaunchPlan) async -> ServerValidation {
		whileValidating?()

		return validation
	}

	func adopt(group: Int32, members: [Int32: Set<ServerOwner>]) -> (any ServerProcess)? {
		adoptedWith = members[group] ?? []

		// The real runner takes a group back only when a recorded member of that same group
		// is still there.
		let present = adoptable[group]?.membership[group] ?? []

		return (members[group] ?? []).contains(where: present.contains) ? adoptable[group] : nil
	}

	func isRunning(_ owner: ServerOwner) -> Bool {
		liveOwners.contains(owner)
	}

	func isStackRunning(_ members: [Int32: Set<ServerOwner>]) -> Bool {
		members.keys.contains { liveGroups.contains($0) }
	}
}

@MainActor
private final class FakeServerProcess: ServerProcess {
	let pid: Int32
	let output: AsyncStream<String>

	var membership: [Int32: Set<ServerOwner>] { [pid: [ServerOwner(pid: pid, startedAt: Int64(pid))]] }

	private(set) var isRunning = true
	var exitStatus: Int32 = 0
	private(set) var didTerminate = false
	private(set) var didKill = false

	private let feed: AsyncStream<String>.Continuation
	private let ignoresTerminate: Bool
	private let ignoresKill: Bool

	init(pid: Int32, ignoresTerminate: Bool = false, ignoresKill: Bool = false) {
		let (lines, feed) = AsyncStream<String>.makeStream()

		self.pid = pid
		self.output = lines
		self.feed = feed
		self.ignoresTerminate = ignoresTerminate
		self.ignoresKill = ignoresKill
	}

	func emit(_ line: String) {
		feed.yield(line)
	}

	func exitCode() async -> Int32 {
		while isRunning {
			try? await Task.sleep(for: .milliseconds(1))
		}
		return exitStatus
	}

	func terminate() {
		didTerminate = true
		guard !ignoresTerminate else { return }
		stop()
	}

	func kill() {
		didKill = true

		guard !ignoresKill else { return }

		stop()
	}

	private func stop() {
		isRunning = false
		feed.finish()
	}
}

enum StoreFailure: Error { case full }

private final class MemoryRecordStore: ServerRecordStore, @unchecked Sendable {
	private(set) var record: ServerRecord?

	init(record: ServerRecord? = nil) {
		self.record = record
	}

	func load(port: Int) -> ServerRecord? {
		record?.port == port ? record : nil
	}

	func save(_ record: ServerRecord) throws {
		if savingFails { throw StoreFailure.full }

		self.record = record
	}

	nonisolated(unsafe) var refusesClaim = false
	nonisolated(unsafe) var savingFails = false

	func claimLaunch(port: Int) -> ServerLaunchClaim? {
		guard !refusesClaim else { return nil }

		return ServerLaunchClaim(
			path: FileManager.default.temporaryDirectory
				.appendingPathComponent("claim-\(UUID().uuidString)").path
		)
	}

	func clear(_ record: ServerRecord) throws {
		guard self.record == record else { return }

		self.record = nil
	}
}
