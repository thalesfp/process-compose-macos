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
/// spawned it has already been given up on.
private func recordedChild(in file: URL) async throws -> String {
	await until { FileManager.default.fileExists(atPath: file.path) }

	return try String(contentsOf: file, encoding: .utf8)
		.trimmingCharacters(in: .whitespacesAndNewlines)
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

		await until { !UnixProcess.isAlive(group) }

		#expect(runner.adopt(group: group, names: ["process-compose"]) == nil)

		let adopted = try #require(runner.adopt(group: group, names: ["sleep"]))

		#expect(adopted.isRunning)

		adopted.kill()
		await until { kill(child, 0) != 0 }

		#expect(kill(child, 0) != 0)
	}
}

@MainActor
struct ServerRecordStoreTests {
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

		#expect(store.load() == theirs)

		try store.clear(theirs)

		#expect(store.load() == nil)
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
		try store.save(ServerRecord(group: 4242, port: 28080, owner: ServerOwner(pid: 900, startedAt: 111)))

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
		#expect(store.load()?.owner.pid == 901)
	}
}

private func plan(in directory: URL) throws -> ServerLaunchPlan {
	try wrapper(in: directory, "sleep 0")
}

private struct NeverReachable: ServerReachability {
	func isReachable(_ address: ServerAddress) async -> Bool { false }
}

@MainActor
private struct RecordedRunner: ServerRunner {
	func run(_ plan: ServerLaunchPlan) throws -> any ServerProcess {
		Issue.record("the recorded server should have been recovered instead of relaunched")

		return try LiveServerRunner().run(plan)
	}

	func validate(_ plan: ServerLaunchPlan) async -> ServerValidation { .valid }

	func isRunning(_ owner: ServerOwner) -> Bool { false }

	func adopt(group: Int32, names: Set<String>) -> (any ServerProcess)? {
		RecoveredServer(pid: group)
	}
}

@MainActor
private final class RecoveredServer: ServerProcess {
	let pid: Int32
	let output = AsyncStream<String> { $0.finish() }

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
