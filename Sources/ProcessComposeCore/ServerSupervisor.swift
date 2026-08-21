import Foundation
import Observation

public enum ServerLifecycle: Sendable, Equatable {
	/// Settings does not say what to start.
	case unconfigured
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

		return (try? await session.data(for: request)) != nil
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

	private var server: (any ServerProcess)?
	private var watchTask: Task<Void, Never>?
	private var plan: ServerLaunchPlan?
	private var address: ServerAddress?
	private var generation = 0

	public init(
		runner: any ServerRunner = LiveServerRunner(),
		reachability: any ServerReachability = LiveServerReachability(),
		records: any ServerRecordStore = FileServerRecordStore(),
		log: ServerLog = ServerLog(),
		grace: Duration = .seconds(5)
	) {
		self.runner = runner
		self.reachability = reachability
		self.records = records
		self.log = log
		self.grace = grace
	}

	public var isOwned: Bool {
		state == .running(owned: true)
	}

	public var canStart: Bool {
		guard plan != nil else { return false }

		switch state {
		case .idle, .failed: return true
		case .unconfigured, .running: return false
		}
	}

	/// Points the supervisor at the server the rest of the app is talking to. A changed
	/// address or plan retires the server started for the previous one.
	public func use(address: ServerAddress?, plan: ServerLaunchPlan?) async {
		if address != self.address || plan != self.plan {
			await stop()
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

	public func stop() async {
		guard let server else {
			state = .idle
			return
		}

		server.terminate()
		await waitForExit(of: server)

		if server.isRunning { server.kill() }

		release()
	}

	/// The app is quitting, so the server it started goes with it. Quitting cannot await,
	/// so this waits in place.
	public func stopOnQuit() {
		guard let server, server.isRunning else {
			release()
			return
		}

		server.terminate()

		let deadline = ContinuousClock.now.advanced(by: grace)
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
		guard
			let record = records.load(),
			record.port == address.port,
			let existing = runner.adopt(pid: record.pid)
		else {
			state = .running(owned: false)
			return
		}

		server = existing
		state = .running(owned: true)
		watch(existing)
	}

	private func start(_ plan: ServerLaunchPlan, generation mine: Int) async {
		let validation = await runner.validate(plan)

		guard isCurrent(mine) else { return }

		if case .failed(let reason) = validation {
			state = .failed(reason: reason)
			return
		}

		do {
			let started = try runner.run(plan)

			server = started
			remember(ServerRecord(pid: started.pid, port: plan.port))
			state = .running(owned: true)
			watch(started)
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
			// A cancelled sleep returns at once, so waiting out the grace period here would
			// spin the main actor instead of pausing on it.
			do {
				try await Task.sleep(for: .milliseconds(50))
			} catch {
				return
			}
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
		do {
			try records.save(record)
		} catch {
			log.append("Could not record the server pid: \(error.localizedDescription)")
		}
	}

	private func forget() {
		do {
			try records.clear()
		} catch {
			log.append("Could not clear the server record: \(error.localizedDescription)")
		}
	}
}
