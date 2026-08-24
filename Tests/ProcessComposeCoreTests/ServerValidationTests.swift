import Foundation
import Testing

@testable import ProcessComposeCore

@MainActor
struct ServerValidationTests {
	@Test("gives up on a check that will not finish, and on what it started")
	func boundsAHangingCheck() async throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("check-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let script = directory.appendingPathComponent("hangs.sh")
		let childFile = directory.appendingPathComponent("child.pid")

		// bash passes its ignored TERM to what it starts, so the child outlives SIGTERM too.
		try """
			#!/bin/bash
			trap '' TERM
			sleep 30 &
			echo $! > "$(dirname "$0")/child.pid"
			wait
			""".write(to: script, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

		let plan = try #require(
			ServerLaunchPlan(
				executablePath: script.path,
				configurationPath: directory.appendingPathComponent("process-compose.yaml").path,
				port: 28080
			)
		)
		// Long enough that a loaded machine still reaches the line recording the child, and
		// far below the thirty seconds the script would otherwise take.
		let runner = LiveServerRunner(validationTimeout: .seconds(3))

		let started = ContinuousClock.now
		let validation = await runner.validate(plan)
		let waited = ContinuousClock.now - started

		#expect(validation == .failed(reason: "The config check did not finish"))
		#expect(waited < .seconds(10))

		let child = try #require(pid_t(try await recordedChild(in: childFile)))

		await until { kill(child, 0) != 0 }

		#expect(kill(child, 0) != 0)
	}

	@Test("gives up on a check that goes quiet without exiting")
	func boundsACheckThatClosesItsOutput() async throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("quiet-check-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let script = directory.appendingPathComponent("quiet.sh")

		// End of file on the pipe says every writer let go, not that the check is over.
		try """
			#!/bin/bash
			exec 1>&- 2>&-
			sleep 30
			""".write(to: script, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

		let plan = try #require(
			ServerLaunchPlan(
				executablePath: script.path,
				configurationPath: directory.appendingPathComponent("process-compose.yaml").path,
				port: 28080
			)
		)
		let runner = LiveServerRunner(validationTimeout: .seconds(1))
		let answer = Answer()

		let checking = Task { await answer.set(runner.validate(plan)) }
		await until { answer.value != nil }
		checking.cancel()

		#expect(answer.value == .failed(reason: "The config check did not finish"))
	}
}

/// Holds the answer so a check that never returns fails the test instead of hanging it.
private final class Answer: @unchecked Sendable {
	private let lock = NSLock()
	private var answer: ServerValidation?

	var value: ServerValidation? {
		lock.lock()
		defer { lock.unlock() }
		return answer
	}

	func set(_ value: ServerValidation) {
		lock.lock()
		answer = value
		lock.unlock()
	}
}

/// The script records its child as it starts, which under load can be after the check that
/// spawned it has already been given up on. The file appears before it holds the number, so
/// what is waited for is a number.
private func recordedChild(in file: URL, within limit: Duration = .seconds(10)) async throws -> String {
	await until({ pid(in: file) != nil }, within: limit)

	guard let recorded = pid(in: file) else { return "" }

	return String(recorded)
}

private func pid(in file: URL) -> pid_t? {
	guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }

	return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func until(_ condition: @Sendable () -> Bool, within limit: Duration = .seconds(10)) async {
	let deadline = ContinuousClock.now.advanced(by: limit)

	while ContinuousClock.now < deadline, !condition() {
		try? await Task.sleep(for: .milliseconds(50))
	}
}

@MainActor
struct ServerProcessTests {
	@Test("stops what a wrapper script started, not just the wrapper")
	func stopsTheWholeGroup() async throws {
		let directory = try scratchDirectory("wrapper")
		defer { try? FileManager.default.removeItem(at: directory) }

		// A wrapper that does not exec leaves the server running as its grandchild.
		let plan = try wrapper(
			in: directory,
			"""
			echo starting the stack
			sleep 30 &
			echo $! > "$(dirname "$0")/child.pid"
			wait
			"""
		)

		let server = try LiveServerRunner().run(plan)
		let lines = server.output
		let printed = Task { () -> String? in
			for await line in lines { return line }
			return nil
		}

		let child = try #require(
			pid_t(try await recordedChild(in: directory.appendingPathComponent("child.pid")))
		)

		#expect(await printed.value == "starting the stack")

		server.terminate()
		await until { kill(child, 0) != 0 }

		#expect(kill(child, 0) != 0)
	}

	@Test("still stops the stack after the wrapper it started with is gone")
	func signalsTheGroupAfterTheLeaderIsReaped() async throws {
		let directory = try scratchDirectory("reaped")
		defer { try? FileManager.default.removeItem(at: directory) }

		// The wrapper exits and lets go of the pipe, so it is reaped while its work runs on.
		let plan = try wrapper(
			in: directory,
			"""
			sleep 30 >/dev/null 2>&1 &
			echo $! > "$(dirname "$0")/child.pid"
			"""
		)

		let server = try LiveServerRunner().run(plan)
		let child = try #require(
			pid_t(try await recordedChild(in: directory.appendingPathComponent("child.pid")))
		)

		let leader = server.pid
		await until { !UnixProcess.isAlive(leader) }

		server.terminate()
		await until { kill(child, 0) != 0 }

		#expect(kill(child, 0) != 0)
	}

	@Test("counts the stack as running while the work outlives the wrapper")
	func tracksTheWholeGroup() async throws {
		let directory = try scratchDirectory("outliving")
		defer { try? FileManager.default.removeItem(at: directory) }

		// The wrapper goes on SIGTERM while what it started keeps stopping its own work,
		// which is what process-compose does with its shutdown commands.
		let plan = try wrapper(
			in: directory,
			"""
			bash -c 'trap "" TERM; sleep 30' &
			echo $! > "$(dirname "$0")/child.pid"
			"""
		)

		let server = try LiveServerRunner().run(plan)
		let child = try #require(
			pid_t(try await recordedChild(in: directory.appendingPathComponent("child.pid")))
		)

		server.terminate()
		try await Task.sleep(for: .milliseconds(500))

		#expect(server.isRunning)

		server.kill()
		await until { kill(child, 0) != 0 }

		#expect(kill(child, 0) != 0)
	}
}

extension ServerProcessTests {
	@Test("takes back a wrapper-started stack after the app that started it is gone")
	func adoptsTheGroupAfterACrash() async throws {
		let directory = try scratchDirectory("crash")
		defer { try? FileManager.default.removeItem(at: directory) }

		// The wrapper exits at once, so its pid is gone while the stack it started is not.
		// The child lets go of the output pipe, which is what lets the wrapper be reaped.
		let plan = try wrapper(
			in: directory,
			"""
			sleep 30 >/dev/null 2>&1 &
			echo $! > "$(dirname "$0")/child.pid"
			"""
		)

		let runner = LiveServerRunner()
		let started = try runner.run(plan)
		let group = started.pid
		let child = try #require(
			pid_t(try await recordedChild(in: directory.appendingPathComponent("child.pid")))
		)

		// What the record would hold: the stack as it was seen while it was still starting,
		// which is what the supervisor writes and keeps refreshed.
		var recorded = started.membership
		let deadline = ContinuousClock.now.advanced(by: .seconds(10))

		while !recorded.values.contains(where: { $0.contains { $0.pid == child } }),
			ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
			recorded = started.membership
		}

		await until { !UnixProcess.isAlive(group) }

		// A group number alone proves nothing: the same number with processes this stack was
		// never recorded as holding is somebody else's group.
		let stranger = ServerOwner(pid: 999_999, startedAt: 1)

		#expect(runner.adopt(group: group, members: [group: [stranger]]) == nil)

		let adopted = try #require(runner.adopt(group: group, members: recorded))

		#expect(adopted.isRunning)

		adopted.kill()
		await until { kill(child, 0) != 0 }

		#expect(kill(child, 0) != 0)
	}
}

@MainActor
struct ServerRecordStoreTests {
	@Test("never waits on a claim this process already holds")
	func claimDoesNotWaitOnItself() throws {
		let directory = try scratchDirectory("claims")
		defer { try? FileManager.default.removeItem(at: directory) }

		let store = FileServerRecordStore(url: directory.appendingPathComponent("server.json"))
		let held = try #require(store.claimLaunch(port: 28080))

		// A wait here would be a wait on this same process, which nothing could end.
		#expect(store.claimLaunch(port: 28080) == nil)
		// A different port is a different stack, and is not made to wait for this one.
		#expect(store.claimLaunch(port: 28099) != nil)

		_ = held
	}

	@Test("keeps a record another copy of the app wrote in its place")
	func clearsOnlyItsOwnRecord() throws {
		let directory = try scratchDirectory("records")
		defer { try? FileManager.default.removeItem(at: directory) }

		let store = FileServerRecordStore(url: directory.appendingPathComponent("server.json"))
		let mine = ServerRecord(group: 100, port: 28080, owner: ServerOwner(pid: 900, startedAt: 1))
		let theirs = ServerRecord(group: 200, port: 28080, owner: ServerOwner(pid: 901, startedAt: 2))

		try store.save(mine)
		try store.save(theirs)
		try store.clear(mine)

		#expect(store.load(port: 28080) == theirs)

		try store.clear(theirs)

		#expect(store.load(port: 28080) == nil)
	}

	@Test("keeps the record of a stack on another port")
	func keepsRecordsOfOtherPorts() throws {
		let directory = try scratchDirectory("ports")
		defer { try? FileManager.default.removeItem(at: directory) }

		let store = FileServerRecordStore(url: directory.appendingPathComponent("server.json"))
		let here = ServerRecord(group: 100, port: 28080, owner: ServerOwner(pid: 900, startedAt: 1))
		let there = ServerRecord(group: 200, port: 28099, owner: ServerOwner(pid: 901, startedAt: 2))

		try store.save(here)
		try store.save(there)

		#expect(store.load(port: 28080) == here)
		#expect(store.load(port: 28099) == there)

		try store.clear(here)

		#expect(store.load(port: 28080) == nil)
		#expect(store.load(port: 28099) == there)
	}
}

extension ServerProcessTests {
	@Test("takes a check in flight with it when the app goes")
	func endsRunningChecksOnQuit() async throws {
		let directory = try scratchDirectory("quitting")
		defer { try? FileManager.default.removeItem(at: directory) }

		let plan = try wrapper(
			in: directory,
			"""
			trap '' TERM
			sleep 30 >/dev/null 2>&1 &
			echo $! > "$(dirname "$0")/child.pid"
			wait
			"""
		)

		let checks = RunningChecks()
		let runner = LiveServerRunner(validationTimeout: .seconds(30), checks: checks)
		let checking = Task { await runner.validate(plan) }
		let child = try #require(
			pid_t(try await recordedChild(in: directory.appendingPathComponent("child.pid")))
		)

		checks.endAll()

		await until { kill(child, 0) != 0 }

		#expect(kill(child, 0) != 0)

		checking.cancel()
	}
}

private func scratchDirectory(_ name: String) throws -> URL {
	let directory = FileManager.default.temporaryDirectory
		.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
	try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

	return directory
}

private func wrapper(in directory: URL, _ body: String) throws -> ServerLaunchPlan {
	let script = directory.appendingPathComponent("wrapper.sh")
	try "#!/bin/bash\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
	try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

	return ServerLaunchPlan(
		executablePath: script.path,
		configurationPath: directory.appendingPathComponent("process-compose.yaml").path,
		port: 28080
	)!
}

@MainActor
struct ServerRecoveryTests {
	@Test("recovers a recorded server without waiting on a lock it already holds")
	func recoversUnderTheRealStore() async throws {
		let directory = try scratchDirectory("recovery")
		defer { try? FileManager.default.removeItem(at: directory) }

		let store = FileServerRecordStore(url: directory.appendingPathComponent("server.json"))
		try store.save(ServerRecord(group: 4242, port: ServerAddress.defaultPort, owner: ServerOwner(pid: 900, startedAt: 111)))

		let supervisor = ServerSupervisor(
			runner: RecordedRunner(),
			reachability: NeverReachable(),
			records: store,
			owner: ServerOwner(pid: 901, startedAt: 222)
		)

		// A deadlock here would hang the suite, so the wait has a deadline of its own.
		let recovering = Task { await supervisor.use(address: .standard, plan: try plan(in: directory)) }
		let deadline = ContinuousClock.now.advanced(by: .seconds(10))

		while supervisor.state != .running(owned: true), ContinuousClock.now < deadline {
			await Task.yield()
			try? await Task.sleep(for: .milliseconds(20))
		}

		_ = try? await recovering.value

		#expect(supervisor.state == .running(owned: true))
		#expect(store.load(port: ServerAddress.defaultPort)?.owner.pid == 901)
	}
}

private func plan(in directory: URL) throws -> ServerLaunchPlan {
	try wrapper(in: directory, "sleep 0")
}

private struct NeverReachable: ServerReachability {
	func look(at address: ServerAddress) async -> ServerPresence { .nothing }
}

@MainActor
private struct RecordedRunner: ServerRunner {
	func run(_ plan: ServerLaunchPlan) throws -> any ServerProcess {
		Issue.record("the recorded server should have been recovered instead of relaunched")

		return try LiveServerRunner().run(plan)
	}

	func validate(_ plan: ServerLaunchPlan) async -> ServerValidation { .valid }

	func isRunning(_ owner: ServerOwner) -> Bool { false }

	func isStackRunning(_ members: [Int32: Set<ServerOwner>]) -> Bool { true }

	func adopt(group: Int32, members: [Int32: Set<ServerOwner>]) -> (any ServerProcess)? {
		RecoveredServer(pid: group)
	}
}

@MainActor
private final class RecoveredServer: ServerProcess {
	let pid: Int32
	let output = AsyncStream<String> { $0.finish() }

	var membership: [Int32: Set<ServerOwner>] { [pid: [ServerOwner(pid: pid, startedAt: Int64(pid))]] }
	var isRunning = true

	init(pid: Int32) {
		self.pid = pid
	}

	func exitCode() async -> Int32 {
		while isRunning { try? await Task.sleep(for: .milliseconds(50)) }
		return 0
	}

	func terminate() { isRunning = false }
	func kill() { isRunning = false }
}

@MainActor
struct ManagedGroupTests {
	@Test("keeps tracking the services of a leader that starts them and exits")
	func tracksServicesOfALeaderThatExits() async throws {
		let directory = try scratchDirectory("vanishing")
		defer { try? FileManager.default.removeItem(at: directory) }

		// A launcher that starts its services in groups of their own, with their own output,
		// and then goes. Nothing links the two once it has, so they have to have been seen
		// while it was still there.
		let plan = try wrapper(
			in: directory,
			"""
			perl -e 'setpgrp(0,0); exec("sleep", "30")' >/dev/null 2>&1 &
			echo $! > "$(dirname "$0")/child.pid"
			sleep 2
			"""
		)

		let server = try LiveServerRunner().run(plan)
		let service = try #require(
			pid_t(try await recordedChild(in: directory.appendingPathComponent("child.pid")))
		)
		let leader = server.pid

		// Seen while the launcher is still there to point at it, which is the whole point.
		var tracked = false
		let deadline = ContinuousClock.now.advanced(by: .seconds(10))

		while !tracked, ContinuousClock.now < deadline {
			tracked = server.membership.values.contains { $0.contains { $0.pid == service } }

			if !tracked { try await Task.sleep(for: .milliseconds(20)) }
		}

		#expect(tracked)

		await until { !UnixProcess.isAlive(leader) }

		#expect(server.isRunning)

		// SIGTERM is for the server to act on, and here there is no server left to act, so
		// the service goes only when the shutdown is forced.
		server.terminate()
		server.kill()
		await until { kill(service, 0) != 0 }

		#expect(kill(service, 0) != 0)
	}

	@Test("leaves a managed service to the server to stop, until the shutdown is forced")
	func leavesGracefulShutdownToTheServer() async throws {
		let directory = try scratchDirectory("orderly")
		defer { try? FileManager.default.removeItem(at: directory) }

		// A server that takes its time stopping its service, as process-compose does when it
		// runs shutdown commands in dependency order.
		let plan = try wrapper(
			in: directory,
			"""
			perl -e 'setpgrp(0,0); exec("sleep", "30")' >/dev/null 2>&1 &
			echo $! > "$(dirname "$0")/child.pid"
			sleep 30
			"""
		)

		let server = try LiveServerRunner().run(plan)
		let service = try #require(
			pid_t(try await recordedChild(in: directory.appendingPathComponent("child.pid")))
		)
		let leader = server.pid

		await until { UnixProcess.groups(under: leader).keys.contains(service) }

		server.terminate()
		await until { !UnixProcess.isAlive(leader) }

		// The server was asked to stop; the service it manages was not signalled behind it.
		#expect(kill(service, 0) == 0)

		server.kill()
		await until { kill(service, 0) != 0 }

		#expect(kill(service, 0) != 0)
	}

	@Test("does not ask a group that has since become someone else's to stop")
	func doesNotSignalARecycledLaunchGroup() async throws {
		let directory = try scratchDirectory("recycled")
		defer { try? FileManager.default.removeItem(at: directory) }

		let plan = try wrapper(
			in: directory,
			"""
			perl -e 'setpgrp(0,0); exec("sleep", "30")' >/dev/null 2>&1 &
			echo $! > "$(dirname "$0")/child.pid"
			sleep 2
			"""
		)

		let server = try LiveServerRunner().run(plan)
		let service = try #require(
			pid_t(try await recordedChild(in: directory.appendingPathComponent("child.pid")))
		)
		let leader = server.pid

		await until { !UnixProcess.isAlive(leader) }

		// The launch group is empty, so its number is free for another group to be given.
		// Asking it to stop now would be asking whoever holds it next.
		server.terminate()

		#expect(server.isRunning)
		#expect(kill(service, 0) == 0)

		server.kill()
		await until { kill(service, 0) != 0 }
	}

	@Test("forgets a group once what it was holding has moved on")
	func forgetsAGroupItsMembersHaveLeft() async throws {
		let directory = try scratchDirectory("moved")
		defer { try? FileManager.default.removeItem(at: directory) }

		// The service starts inside the launch group and then leaves it, which is how it is
		// first seen under a group it no longer belongs to.
		let plan = try wrapper(
			in: directory,
			"""
			perl -e 'select(undef, undef, undef, 0.2); setpgrp(0,0); exec("sleep", "30")' >/dev/null 2>&1 &
			echo $! > "$(dirname "$0")/child.pid"
			sleep 30
			"""
		)

		let server = try LiveServerRunner().run(plan)
		let service = try #require(
			pid_t(try await recordedChild(in: directory.appendingPathComponent("child.pid")))
		)

		await until { UnixProcess.group(of: service) == service }

		var held = server.membership
		let deadline = ContinuousClock.now.advanced(by: .seconds(10))

		while held[service] == nil, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
			held = server.membership
		}

		// Recorded under the group it leads now, not the one it was born in.
		#expect(held[service]?.contains { $0.pid == service } == true)
		#expect(held.values.flatMap { $0 }.filter { $0.pid == service }.count == 1)

		server.kill()
		await until { kill(service, 0) != 0 }
	}

	@Test("finds a service started long after the stack moved out of its launch group")
	func findsAServiceStartedLater() async throws {
		let directory = try scratchDirectory("later")
		defer { try? FileManager.default.removeItem(at: directory) }

		// The server moves into a group of its own, the launcher goes, and only well after
		// the close watching has stopped does the server start a service.
		let plan = try wrapper(
			in: directory,
			"""
			perl -e '
				setpgrp(0,0);
				select(undef, undef, undef, 6);
				my $pid = fork();
				if ($pid == 0) { exec("sleep", "30"); }
				open(my $out, ">", "$ARGV[0]/service.pid"); print $out $pid; close($out);
				sleep 30;
			' "$(dirname "$0")" >/dev/null 2>&1 &
			echo $! > "$(dirname "$0")/child.pid"
			sleep 2
			"""
		)

		let server = try LiveServerRunner().run(plan)
		_ = try await recordedChild(in: directory.appendingPathComponent("child.pid"))

		let service = try #require(
			pid_t(try await recordedChild(in: directory.appendingPathComponent("service.pid"), within: .seconds(30)))
		)

		var found = false
		let deadline = ContinuousClock.now.advanced(by: .seconds(20))

		while !found, ContinuousClock.now < deadline {
			found = server.membership.values.contains { $0.contains { $0.pid == service } }

			if !found { try await Task.sleep(for: .milliseconds(100)) }
		}

		#expect(found)

		server.kill()
		await until { kill(service, 0) != 0 }

		#expect(kill(service, 0) != 0)
	}

	@Test("takes back a stack that had moved out of the group it was launched in")
	func adoptsAStackThatMovedGroups() async throws {
		let directory = try scratchDirectory("moved-crash")
		defer { try? FileManager.default.removeItem(at: directory) }

		// The launcher hands over to a server in a group of its own and exits, so the group
		// the stack was launched in is gone by the time it has to be taken back.
		let plan = try wrapper(
			in: directory,
			"""
			perl -e 'setpgrp(0,0); exec("sleep", "30")' >/dev/null 2>&1 &
			echo $! > "$(dirname "$0")/child.pid"
			sleep 2
			"""
		)

		let runner = LiveServerRunner()
		let started = try runner.run(plan)
		let launchGroup = started.pid
		let server = try #require(
			pid_t(try await recordedChild(in: directory.appendingPathComponent("child.pid")))
		)

		var recorded = started.membership
		let deadline = ContinuousClock.now.advanced(by: .seconds(10))

		while recorded[server] == nil, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
			recorded = started.membership
		}

		await until { !UnixProcess.isAlive(launchGroup) }

		let adopted = try #require(runner.adopt(group: launchGroup, members: recorded))

		#expect(adopted.isRunning)

		adopted.kill()
		await until { kill(server, 0) != 0 }

		#expect(kill(server, 0) != 0)
	}

	@Test("asks the server to stop even after it moved out of its launch group")
	func asksTheMovedServerToStop() async throws {
		let directory = try scratchDirectory("moved-stop")
		defer { try? FileManager.default.removeItem(at: directory) }

		let plan = try wrapper(
			in: directory,
			"""
			perl -e 'setpgrp(0,0); exec("sleep", "30")' >/dev/null 2>&1 &
			echo $! > "$(dirname "$0")/child.pid"
			sleep 2
			"""
		)

		let server = try LiveServerRunner().run(plan)
		let moved = try #require(
			pid_t(try await recordedChild(in: directory.appendingPathComponent("child.pid")))
		)
		let launchGroup = server.pid

		var tracked = false
		let deadline = ContinuousClock.now.advanced(by: .seconds(10))

		while !tracked, ContinuousClock.now < deadline {
			tracked = server.membership[moved] != nil

			if !tracked { try await Task.sleep(for: .milliseconds(20)) }
		}

		#expect(tracked)
		await until { !UnixProcess.isAlive(launchGroup) }

		// Asked, not forced: the launch group is empty, so the request has to reach the group
		// the server moved into.
		server.terminate()
		await until { kill(moved, 0) != 0 }

		#expect(kill(moved, 0) != 0)
	}

	@Test("records nothing more once everything it was holding has gone")
	func recordsNothingAfterTheStackIsGone() async throws {
		let directory = try scratchDirectory("gone")
		defer { try? FileManager.default.removeItem(at: directory) }

		let plan = try wrapper(in: directory, "sleep 0.2")

		let server = try LiveServerRunner().run(plan)

		let deadline = ContinuousClock.now.advanced(by: .seconds(10))

		while server.isRunning, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}

		#expect(server.membership.isEmpty)

		// The number the group had is free now, and whatever is given it next is not ours.
		try await Task.sleep(for: .milliseconds(300))

		#expect(server.membership.isEmpty)
		#expect(server.isRunning == false)
	}

	@Test("stops a service the server put in a group of its own")
	func stopsAServiceInItsOwnGroup() async throws {
		let directory = try scratchDirectory("managed")
		defer { try? FileManager.default.removeItem(at: directory) }

		// The service leads a group of its own while staying a child, which is how
		// process-compose runs one, so a signal to the launch group alone never reaches it.
		let plan = try wrapper(
			in: directory,
			"""
			perl -e 'setpgrp(0,0); exec("sleep", "30")' >/dev/null 2>&1 &
			echo $! > "$(dirname "$0")/child.pid"
			sleep 30
			"""
		)

		let server = try LiveServerRunner().run(plan)
		let service = try #require(
			pid_t(try await recordedChild(in: directory.appendingPathComponent("child.pid")))
		)

		let launch = server.pid
		await until { UnixProcess.groups(under: launch).keys.contains(service) }

		server.kill()
		await until { kill(service, 0) != 0 }

		#expect(kill(service, 0) != 0)
	}
}
