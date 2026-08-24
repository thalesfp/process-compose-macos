import Foundation
import Observation

public enum ServerLifecycle: Sendable, Equatable {
	/// Settings does not say what to start.
	case unconfigured
	/// Settings points at another machine, where the app cannot start anything.
	case remote
	case idle
	case running(owned: Bool)
	case failed(reason: String)
}

/// What is on an address.
public enum ServerPresence: Sendable, Equatable {
	case nothing
	/// Something answers, but not as a process-compose project. Starting a server here would
	/// only fail on a port already taken.
	case occupied
	case processCompose
}

public protocol ServerReachability: Sendable {
	func look(at address: ServerAddress) async -> ServerPresence
}

public struct LiveServerReachability: ServerReachability {
	private let session: URLSession

	public init(session: URLSession = .shared) {
		self.session = session
	}

	public func look(at address: ServerAddress) async -> ServerPresence {
		var request = URLRequest(url: address.url(path: "/project/state"))
		request.timeoutInterval = 2

		guard let (data, response) = try? await session.data(for: request) else { return .nothing }

		return Self.presence(status: (response as? HTTPURLResponse)?.statusCode, body: data)
	}

	// URLSession returns a 404, a 401 or a 500 as a success, and any service can hold the
	// port, so the project the server reports is what separates process-compose from
	// something else answering. Anything else answering still means the port is taken.
	static func presence(status: Int?, body: Data) -> ServerPresence {
		guard let status else { return .nothing }

		guard status == 200, (try? JSONDecoder().decode(ProjectState.self, from: body)) != nil else {
			return .occupied
		}

		return .processCompose
	}
}

/// Owns the server process itself: attaches to one already on the port, starts one when
/// nothing answers, and stops the one it started.
@MainActor
@Observable
public final class ServerSupervisor {
	public private(set) var state: ServerLifecycle = .idle
	public let log: ServerLog

	private let runner: any ServerRunner
	private let reachability: any ServerReachability
	private let records: any ServerRecordStore
	private let grace: Duration
	private let owner: ServerOwner

	private var server: (any ServerProcess)?
	private var watchTask: Task<Void, Never>?
	private var stopTask: Task<Void, Never>?
	private var launchTask: Task<Void, Never>?
	private var useTask: Task<Void, Never>?
	private var useInputs: Inputs?
	private var useToken = 0
	private var record: ServerRecord?
	private var plan: ServerLaunchPlan?
	private var address: ServerAddress?
	private var generation = 0

	public init(
		runner: any ServerRunner = LiveServerRunner(),
		reachability: any ServerReachability = LiveServerReachability(),
		records: any ServerRecordStore = FileServerRecordStore(),
		log: ServerLog = ServerLog(),
		// process-compose gives each of its own shutdown commands ten seconds by default, and
		// runs them one after another when the config asks for an ordered shutdown, so a
		// stack needs considerably longer than one of them before anything is forced.
		grace: Duration = .seconds(60),
		owner: ServerOwner = .current
	) {
		self.runner = runner
		self.reachability = reachability
		self.records = records
		self.log = log
		self.grace = grace
		self.owner = owner
	}

	public var isOwned: Bool {
		state == .running(owned: true)
	}

	public var canStart: Bool {
		guard plan != nil, address?.isLoopback == true else { return false }

		switch state {
		case .idle, .failed: return true
		case .unconfigured, .remote, .running: return false
		}
	}

	/// What the window is asking for.
	private struct Inputs: Equatable {
		let address: ServerAddress?
		let plan: ServerLaunchPlan?
	}

	/// Points the supervisor at the server the rest of the app is talking to. A changed
	/// address or plan retires the server started for the previous one.
	///
	/// The work is held by the supervisor rather than by whoever asked for it: a window
	/// being rebuilt or closed must not abandon a launch half way, and asking again for what
	/// is already being done joins it rather than starting it over.
	public func use(address: ServerAddress?, plan: ServerLaunchPlan?) async {
		let wanted = Inputs(address: address, plan: plan)

		if let useTask, useInputs == wanted {
			await useTask.value
			return
		}

		generation += 1
		let mine = generation
		useToken += 1
		let token = useToken
		useInputs = wanted

		let work = Task { await self.apply(wanted, generation: mine) }
		useTask = work

		await work.value

		// Only the request that still holds the slot may give it up: an earlier one asking
		// for exactly the same thing would otherwise clear a later one that is still going.
		if useToken == token { useTask = nil }
	}

	private func apply(_ wanted: Inputs, generation mine: Int) async {
		// A shutdown can take a minute, and the settings can come back to where they started
		// in that time. Waiting here is what keeps the two from overlapping.
		if let stopTask { await stopTask.value }

		guard isCurrent(mine) else { return }

		if wanted.address != address || wanted.plan != plan {
			await stop()

			guard isCurrent(mine) else { return }
		}

		address = wanted.address
		plan = wanted.plan

		guard let address = wanted.address else {
			state = .unconfigured
			return
		}

		// A server this app started and is still holding stays its own, whatever a probe says
		// at this moment: a stack that is slow to answer is not a stack that is not ours.
		if let server, server.isRunning {
			state = .running(owned: true)
			return
		}

		let presence = await reachability.look(at: address)

		guard isCurrent(mine) else { return }

		switch presence {
		case .processCompose:
			attach(on: address)
			return
		case .occupied:
			state = .failed(reason: "Something that is not process-compose answers on port \(address.port)")
			return
		case .nothing:
			break
		}

		guard address.isLoopback else {
			state = .remote
			return
		}

		guard let plan = wanted.plan else {
			state = .unconfigured
			return
		}

		await launch(plan, generation: mine)
	}

	/// Starts the configured server on request, after a failure or after the user stopped it.
	public func start() async {
		guard let plan, canStart else { return }

		generation += 1

		await launch(plan, generation: generation)
	}

	/// The stack went away. A server the app started reports its own exit, but one started
	/// elsewhere only shows up as a dead port, and starting one becomes the user's to do again.
	public func recheck() async {
		guard state == .running(owned: false), let address else { return }

		generation += 1
		let mine = generation

		let presence = await reachability.look(at: address)

		guard isCurrent(mine), presence == .nothing else { return }

		state = .idle
	}

	/// Shutting a stack down outlives whoever asked for it: a settings edit that cancels its
	/// own task must not leave process-compose half way through stopping its processes.
	public func stop() async {
		if let stopTask {
			await stopTask.value
			return
		}

		let stopping = Task { await self.shutDown() }
		stopTask = stopping
		await stopping.value
		stopTask = nil
	}

	private func shutDown() async {
		guard let server else {
			state = .idle
			return
		}

		let stopping = server

		server.terminate()
		await waitForExit(of: server)

		if server.isRunning {
			server.kill()
			await waitForExit(of: server, within: .seconds(2))
		}

		// A stack that survived SIGKILL is still out there, and dropping the record would
		// leave nothing able to find it again.
		guard !server.isRunning else {
			state = .failed(reason: "The stack is still running and could not be stopped")
			return
		}

		// Another server may have been started while this one was being stopped, and it is
		// not this shutdown's to retire.
		guard self.server === stopping else { return }

		release()
	}

	/// A quit the app never sees coming, such as a log out, cannot await, so this waits in
	/// place and gives the stack less room than `stop` does.
	public func stopOnQuit() {
		// A copy of the app that started nothing leaves the record for the copy that did.
		guard let server else {
			state = .idle
			return
		}

		guard server.isRunning else {
			release()
			return
		}

		server.terminate()

		let deadline = ContinuousClock.now.advanced(by: .seconds(5))
		while server.isRunning, ContinuousClock.now < deadline {
			usleep(50_000)
		}

		if server.isRunning {
			server.kill()

			let hard = ContinuousClock.now.advanced(by: .seconds(2))
			while server.isRunning, ContinuousClock.now < hard { usleep(50_000) }
		}

		// A stack that survived SIGKILL is still out there, and dropping the record would
		// leave the next run nothing to find it with.
		guard !server.isRunning else { return }

		release()
	}

	/// Settings writes a preference per keystroke, so a probe can still be in flight when
	/// the inputs behind it are gone. Its answer must not start a server for them.
	private func isCurrent(_ mine: Int) -> Bool {
		mine == generation
	}

	/// `held` is the claim the caller already has, if any.
	private func attach(on address: ServerAddress, under held: ServerLaunchClaim? = nil) {
		if let server, server.isRunning {
			state = .running(owned: true)
			return
		}

		guard address.isLoopback, takeOver(port: address.port, under: held) else {
			state = .running(owned: false)
			return
		}
	}

	/// Takes a recorded server over, under the same claim a launch takes, and writes this
	/// app into the record. Ownership that is not written down is ownership two copies can
	/// both believe they have, and either quitting would stop the stack under the other.
	/// `held` is the claim the caller already has. Taking a second one for the same file
	/// would wait on a lock this process is holding, which is a wait that never ends.
	private func takeOver(port: Int, under held: ServerLaunchClaim?) -> Bool {
		let claim = held ?? records.claimLaunch(port: port)

		guard claim != nil else { return false }

		defer { _ = claim }

		guard
			let recorded = records.load(port: port),
			// A record whose app is still running belongs to that copy, and stopping its
			// server would take the stack out from under it.
			recorded.owner == owner || !runner.isRunning(recorded.owner),
			let existing = runner.adopt(group: recorded.group, members: recorded.membership)
		else { return false }

		let mine = ServerRecord(
			group: recorded.group,
			port: recorded.port,
			owner: owner,
			members: existing.membership
		)

		do {
			try records.save(mine)
		} catch {
			log.append("Could not take the server over: \(error.localizedDescription)")
			return false
		}

		server = existing
		record = mine
		state = .running(owned: true)
		watch(existing)

		return true
	}

	/// One launch at a time. A second attempt while the first is still deciding would race it
	/// for the claim, and the claim is the thing that says only one server starts.
	private func launch(_ plan: ServerLaunchPlan, generation mine: Int) async {
		if let launchTask { await launchTask.value }

		guard isCurrent(mine), server == nil else { return }

		let launching = Task { await self.start(plan, generation: mine) }
		launchTask = launching
		await launching.value
		launchTask = nil
	}

	/// The claim never waits, so a copy of the app that is a moment ahead is given time
	/// rather than reported as a conflict at once.
	private func claimLaunch(port: Int) async -> ServerLaunchClaim? {
		for attempt in 0 ..< 10 {
			if let claim = records.claimLaunch(port: port) { return claim }

			guard attempt < 9 else { break }

			try? await Task.sleep(for: .milliseconds(200))
		}

		return nil
	}

	private func start(_ plan: ServerLaunchPlan, generation mine: Int) async {
		let validation = await runner.validate(plan)

		guard isCurrent(mine) else { return }

		if case .failed(let reason) = validation {
			state = .failed(reason: reason)
			return
		}

		// Validation takes as long as the config does, and another copy of the app can claim
		// the port while it runs, so the answer from before it is no longer good enough. The
		// claim is held from that last look until the record is written.
		// Without the claim there is no exclusion between copies of the app, and without the
		// record a crash leaves the stack unrecoverable. Neither is worth starting without.
		guard let claim = await claimLaunch(port: plan.port) else {
			state = .failed(reason: "Could not claim the right to start a server")
			return
		}

		guard isCurrent(mine) else { return }

		if let address {
			let presence = await reachability.look(at: address)

			guard isCurrent(mine) else { return }

			switch presence {
			case .processCompose:
				attach(on: address, under: claim)
				return
			case .occupied:
				state = .failed(reason: "Something that is not process-compose answers on port \(address.port)")
				return
			case .nothing:
				break
			}
		}

		guard isCurrent(mine) else { return }

		// A server that is up but not answering yet still owns the port, and starting a
		// second one would only replace the record that makes the first recoverable.
		if let recorded = records.load(port: plan.port) {
			if recorded.owner != owner, runner.isRunning(recorded.owner) {
				state = .running(owned: false)
				return
			}

			if takeOver(port: plan.port, under: claim) { return }

			// The recorded stack is still there but could not be taken over. Starting a
			// second one would replace the only record that can still find the first.
			if runner.isStackRunning(recorded.membership) {
				state = .failed(
					reason: "A server is already running on port \(plan.port) that this app cannot take over"
				)
				return
			}
		}

		do {
			let started = try runner.run(plan)

			// Held from the moment it exists, so a quit in the next instant still finds it.
			server = started
			watch(started)

			let mine = ServerRecord(
				group: started.pid,
				port: plan.port,
				owner: owner,
				members: started.membership
			)

			do {
				try records.save(mine)
			} catch {
				let failure = "Could not record the server: \(error.localizedDescription)"

				await shutDown()

				// A stack that would not stop has its own answer, which is the one to keep.
				if case .failed = state { return }

				state = .failed(reason: failure)
				return
			}

			record = mine
			state = .running(owned: true)
			_ = claim
		} catch {
			state = .failed(reason: error.localizedDescription)
		}
	}

	/// The stack changes shape as it runs: a wrapper hands over to process-compose, which
	/// starts and restarts services. The record follows it, or a later run would look for
	/// processes that have since been replaced.
	private func rememberMembers(of started: any ServerProcess) {
		guard let current = record, server === started else { return }

		let members = started.membership

		guard !members.isEmpty else { return }

		let updated = ServerRecord(
			group: current.group,
			port: current.port,
			owner: current.owner,
			members: members
		)

		guard updated != current else { return }

		do {
			try records.save(updated)
			record = updated
		} catch {
			log.append("Could not record what the server is running: \(error.localizedDescription)")
		}
	}

	private func watch(_ started: any ServerProcess) {
		watchTask?.cancel()
		watchTask = Task { [weak self] in
			let following = Task { [weak self] in
				// A wrapper hands over within milliseconds, and a crash before that reached
				// the record would leave it naming a process that has gone.
				let closely = ContinuousClock.now.advanced(by: .seconds(5))

				while !Task.isCancelled {
					let interval: Duration = ContinuousClock.now < closely ? .milliseconds(100) : .seconds(3)

					try? await Task.sleep(for: interval)
					self?.rememberMembers(of: started)
				}
			}
			defer { following.cancel() }

			let exit = Task { await started.exitCode() }

			for await line in started.output {
				self?.log.append(line)
			}

			let code = await exit.value

			guard let self, self.server === started else { return }

			self.server = nil
			self.forget()
			self.state = code == 0 ? .idle : .failed(reason: "The server exited with status \(code)")
		}
	}

	private func waitForExit(of server: any ServerProcess, within limit: Duration? = nil) async {
		let deadline = ContinuousClock.now.advanced(by: limit ?? grace)

		while server.isRunning, ContinuousClock.now < deadline {
			try? await Task.sleep(for: .milliseconds(50))
		}
	}

	private func release() {
		watchTask?.cancel()
		watchTask = nil
		server = nil
		forget()
		state = .idle
	}

	private func forget() {
		guard let record else { return }

		self.record = nil

		do {
			try records.clear(record)
		} catch {
			log.append("Could not clear the server record: \(error.localizedDescription)")
		}
	}
}
