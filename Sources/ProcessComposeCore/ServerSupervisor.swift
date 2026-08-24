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

/// Answers whether something is already serving the API on an address.
public protocol ServerReachability: Sendable {
	func isReachable(_ address: ServerAddress) async -> Bool
}

public struct LiveServerReachability: ServerReachability {
	private let session: URLSession

	public init(session: URLSession = .shared) {
		self.session = session
	}

	public func isReachable(_ address: ServerAddress) async -> Bool {
		var request = URLRequest(url: address.url(path: "/project/state"))
		request.timeoutInterval = 2

		guard let (data, response) = try? await session.data(for: request) else { return false }

		return Self.answers(status: (response as? HTTPURLResponse)?.statusCode, body: data)
	}

	// URLSession returns a 404 or a 500 as a success, and any service can hold the port, so
	// the project the server reports is what separates it from something else answering.
	static func answers(status: Int?, body: Data) -> Bool {
		guard status == 200 else { return false }

		return (try? JSONDecoder().decode(ProjectState.self, from: body)) != nil
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
	private var record: ServerRecord?
	private var plan: ServerLaunchPlan?
	private var address: ServerAddress?
	private var generation = 0

	public init(
		runner: any ServerRunner = LiveServerRunner(),
		reachability: any ServerReachability = LiveServerReachability(),
		records: any ServerRecordStore = FileServerRecordStore(),
		log: ServerLog = ServerLog(),
		// process-compose runs its own shutdown commands, which it gives ten seconds by
		// default, so a stack has to be allowed to finish before anything is forced.
		grace: Duration = .seconds(12),
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

	/// Points the supervisor at the server the rest of the app is talking to. A changed
	/// address or plan retires the server started for the previous one.
	public func use(address: ServerAddress?, plan: ServerLaunchPlan?) async {
		// Stopping a server is the first thing this does, so a request already abandoned
		// must not get that far.
		guard !Task.isCancelled else { return }

		if address != self.address || plan != self.plan {
			await stop()

			// Waiting out a shutdown takes long enough for newer settings to arrive, and
			// this request must not put its own back over them.
			guard !Task.isCancelled else { return }
		}

		generation += 1
		let mine = generation

		self.address = address
		self.plan = plan

		guard let address else {
			state = .unconfigured
			return
		}

		let reachable = await reachability.isReachable(address)

		guard isCurrent(mine) else { return }

		if reachable {
			attach(on: address)
			return
		}

		guard address.isLoopback else {
			state = .remote
			return
		}

		guard let plan else {
			state = .unconfigured
			return
		}

		await start(plan, generation: mine)
	}

	/// Starts the configured server on request, after a failure or after the user stopped it.
	public func start() async {
		guard let plan, canStart else { return }

		generation += 1

		await start(plan, generation: generation)
	}

	/// The stack went away. A server the app started reports its own exit, but one started
	/// elsewhere only shows up as a dead port, and starting one becomes the user's to do again.
	public func recheck() async {
		guard state == .running(owned: false), let address else { return }

		generation += 1
		let mine = generation

		let reachable = await reachability.isReachable(address)

		guard isCurrent(mine), !reachable else { return }

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

		server.terminate()
		await waitForExit(of: server)

		if server.isRunning { server.kill() }

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

		if server.isRunning { server.kill() }

		release()
	}

	/// Settings writes a preference per keystroke, so a probe can still be in flight when
	/// the inputs behind it are gone. Its answer must not start a server for them.
	private func isCurrent(_ mine: Int) -> Bool {
		!Task.isCancelled && mine == generation
	}

	private func attach(on address: ServerAddress) {
		if let server, server.isRunning {
			state = .running(owned: true)
			return
		}

		guard
			address.isLoopback,
			let record = records.load(),
			record.port == address.port,
			// A record whose app is still running belongs to that copy, and stopping its
			// server would take the stack out from under it.
			record.owner == owner || !runner.isRunning(record.owner),
			let existing = runner.adopt(group: record.group, names: launchNames)
		else {
			state = .running(owned: false)
			return
		}

		server = existing
		self.record = record
		state = .running(owned: true)
		watch(existing)
	}

	/// What the app would have spawned: process-compose itself, or the script configured to
	/// run it.
	private var launchNames: Set<String> {
		["process-compose", plan?.executable.lastPathComponent].compactMap { $0 }.reduce(into: Set()) {
			$0.insert($1)
		}
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
		let claim = records.claimLaunch()

		if let address, await reachability.isReachable(address) {
			guard isCurrent(mine) else { return }

			attach(on: address)
			return
		}

		guard isCurrent(mine) else { return }

		// A server that is up but not answering yet still owns the port, and starting a
		// second one would only replace the record that makes the first recoverable.
		if let recorded = records.load(), recorded.port == plan.port {
			if recorded.owner != owner, runner.isRunning(recorded.owner) {
				state = .running(owned: false)
				return
			}

			if let recovered = runner.adopt(group: recorded.group, names: launchNames) {
				server = recovered
				record = recorded
				state = .running(owned: true)
				watch(recovered)
				return
			}
		}

		do {
			let started = try runner.run(plan)

			server = started
			remember(ServerRecord(group: started.pid, port: plan.port, owner: owner))
			state = .running(owned: true)
			watch(started)
			_ = claim
		} catch {
			state = .failed(reason: error.localizedDescription)
		}
	}

	private func watch(_ started: any ServerProcess) {
		watchTask?.cancel()
		watchTask = Task { [weak self] in
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

	private func waitForExit(of server: any ServerProcess) async {
		let deadline = ContinuousClock.now.advanced(by: grace)

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

	// Losing the record costs the next run its chance to take this server back.
	private func remember(_ record: ServerRecord) {
		self.record = record

		do {
			try records.save(record)
		} catch {
			log.append("Could not record the server pid: \(error.localizedDescription)")
		}
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
