import Foundation
import Observation

public enum StackPower: Sendable, Equatable {
	case canStart
	case canStop
	case unavailable
}

public enum ConnectionState: Sendable, Equatable {
	case connecting
	case connected
	case disconnected(reason: String)
}

@MainActor
@Observable
public final class StackViewModel {
	public private(set) var connection: ConnectionState = .connecting
	public private(set) var project: ProjectState?
	public private(set) var lastError: String?

	/// The row the list and the log pane share. Owned here so the menu bar can act on it.
	public var selection: String?

	/// Whether the window is asking the user to confirm stopping every process. Owned
	/// here because both the toolbar button and the menu bar item raise it.
	public var isConfirmingStopStack = false

	public private(set) var isChangingStack = false

	public var runningProcesses: [ProcessState] {
		processes.filter(\.canStop)
	}

	public var startableProcesses: [ProcessState] {
		processes.filter { $0.canStart && $0.status != .disabled }
	}

	/// Which way the power button points.
	public var power: StackPower {
		if !runningProcesses.isEmpty { return .canStop }
		return startableProcesses.isEmpty ? .unavailable : .canStart
	}

	/// Whether the server can act on the power button right now.
	public var canChangePower: Bool {
		connection == .connected && !isChangingStack && power != .unavailable
	}

	/// Stopping asks first because it is destructive; starting does not.
	public func togglePower() {
		switch power {
		case .canStop: isConfirmingStopStack = true
		case .canStart: Task { await startStack() }
		case .unavailable: break
		}
	}

	public var selectedProcess: ProcessState? {
		selection.flatMap { statesByName[$0] }
	}

	public var processes: [ProcessState] {
		statesByName.values.sorted { left, right in
			left.namespace == right.namespace
				? left.name < right.name
				: left.namespace < right.namespace
		}
	}

	public var groups: [ProjectGroup] {
		ProcessGrouping.groups(for: processes, projects: projectsByProcess)
	}

	public var sections: [StackSection] {
		ProcessGrouping.sections(for: groups, kinds: kinds)
	}

	/// What each process is for, decided from its config and how it behaves.
	public var kinds: [String: ProcessKind] {
		Dictionary(
			uniqueKeysWithValues: processes.map {
				($0.name, ProcessKind.of(state: $0, configuration: configurations[$0.name]))
			}
		)
	}

	/// The server reports these once per connection, but processes start and stop between
	/// connections, so the counts come from the live states instead.
	public var runningCount: Int { runningProcesses.count }
	public var processCount: Int { processes.count }

	/// Uptime keeps advancing after the snapshot that carried it. Time passing changes
	/// nothing observable on its own, so a ticker republishes this once a second.
	public private(set) var uptime: Duration?

	@MainActor
	func refreshUptime() {
		guard let project, let projectReadAt else {
			uptime = nil
			return
		}
		uptime = project.upTime + .seconds(now().timeIntervalSince(projectReadAt))
	}

	public var usage: ResourceUsage {
		ResourceUsage.total(of: processes)
	}

	private var busy: Set<String> = []
	private var statesByName: [String: ProcessState] = [:]
	private var configurations: [String: ProcessConfiguration] = [:]

	private var projectsByProcess: [String: String] {
		configurations.compactMapValues { ProcessGrouping.project(forWorkingDir: $0.workingDir) }
	}
	private var client: any ProcessComposeClient
	private let retryDelay: Duration
	private let now: () -> Date
	private var projectReadAt: Date?
	private var generation = 0
	private var streamTask: Task<Void, Never>?
	private var clockTask: Task<Void, Never>?

	public init(
		client: any ProcessComposeClient,
		retryDelay: Duration = .seconds(2),
		now: @escaping () -> Date = Date.init
	) {
		self.client = client
		self.retryDelay = retryDelay
		self.now = now
	}

	private func connect() {
		let mine = generation

		clockTask?.cancel()
		clockTask = Reconnecting.loop(every: .seconds(1)) { [weak self] in
			await self?.refreshUptime()
		}

		streamTask?.cancel()
		streamTask = Reconnecting.loop(every: retryDelay) { [weak self] in
			await self?.observe(mine)
		}
	}

	/// There is no server to talk to until Settings is corrected, so nothing is started
	/// and the window says why.
	public func refuseAddress(_ reason: String) {
		generation += 1
		streamTask?.cancel()
		streamTask = nil
		clockTask?.cancel()
		clockTask = nil
		statesByName = [:]
		project = nil
		uptime = nil
		selection = nil
		connection = .disconnected(reason: reason)
	}

	/// Points the view model at a different server and starts over.
	public func use(_ client: any ProcessComposeClient) {
		generation += 1
		self.client = client
		connection = .connecting
		statesByName = [:]
		project = nil
		lastError = nil
		connect()
	}

	public func isBusy(_ name: String?) -> Bool {
		name.map(busy.contains) ?? false
	}

	public func canStart(_ name: String?) -> Bool {
		guard let name, let state = statesByName[name] else { return false }
		return state.canStart && !busy.contains(name)
	}

	public func canStop(_ name: String?) -> Bool {
		guard let name, let state = statesByName[name] else { return false }
		return state.canStop && !busy.contains(name)
	}

	public func startProcess(_ name: String) async {
		await act(on: name) { try await self.client.start(name) }
	}

	public func stopProcess(_ name: String) async {
		await act(on: name) { try await self.client.stop(name) }
	}

	public func restartProcess(_ name: String) async {
		await act(on: name) { try await self.client.restart(name) }
	}

	/// Starts every process the stack defines. Processes the config disabled stay off,
	/// because switching one of those on is a per-process decision made on its row.
	public func startStack() async {
		await applyToStack(startableProcesses.map(\.name), failureVerb: "start") {
			try await self.client.start($0)
		}
	}

	public func stopStack() async {
		await applyToStack(runningProcesses.map(\.name), failureVerb: "stop") {
			try await self.client.stop($0)
		}
	}

	// One process at a time: process-compose brings up a process's dependencies with it,
	// so firing the whole list at once reports the dependencies as already running.
	private func applyToStack(
		_ names: [String],
		failureVerb: String,
		_ operation: (String) async throws -> Void
	) async {
		guard !names.isEmpty else { return }

		isChangingStack = true
		defer { isChangingStack = false }

		var failures: [String] = []

		for name in names {
			busy.insert(name)
			do {
				try await operation(name)
			} catch {
				failures.append(name)
			}
			busy.remove(name)
		}

		lastError = failures.isEmpty
			? nil
			: "Could not \(failureVerb) \(failures.joined(separator: ", "))"
	}

	public func dismissError() {
		lastError = nil
	}

	private func act(on name: String, _ operation: () async throws -> Void) async {
		busy.insert(name)
		defer { busy.remove(name) }

		do {
			try await operation()
			lastError = nil
		} catch {
			lastError = "\(name): \(error.localizedDescription)"
		}
	}

	/// One connection attempt: load the authoritative list, then follow the event
	/// stream until it ends. `connect()` is this in a retry loop.
	public func observe() async {
		await observe(generation)
	}

	/// Only `use` and `refuseAddress` advance the generation. An observation that starts
	/// late must not claim to be the newest, or it would retire the connection that
	/// replaced it.
	private func observe(_ mine: Int) async {
		do {
			let snapshot = try await client.processes()
			guard isCurrent(mine) else { return }
			statesByName = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.name, $0) })

			async let state = try? await client.projectState()
			async let loaded = loadConfigurations(for: snapshot.map(\.name))
			let loadedProject = await state
			let loadedConfigurations = await loaded
			guard isCurrent(mine) else { return }

			project = loadedProject
			projectReadAt = loadedProject == nil ? nil : now()
			refreshUptime()
			configurations = loadedConfigurations
			reconcileSelection()
			connection = .connected

			for try await event in client.stateEvents() {
				guard isCurrent(mine) else { return }
				statesByName[event.state.name] = event.state
			}

			guard isCurrent(mine) else { return }
			connection = .disconnected(reason: ProcessComposeError.streamClosed.localizedDescription)
		} catch is CancellationError {
			return
		} catch {
			guard isCurrent(mine) else { return }
			connection = .disconnected(reason: error.localizedDescription)
		}
	}

	/// Every await in `observe` is a point where the connection can be cancelled or
	/// replaced. Cancellation ends a stream normally rather than throwing, and `try?`
	/// swallows it outright, so an abandoned attempt would otherwise publish over the
	/// connection that replaced it.
	private func isCurrent(_ observation: Int) -> Bool {
		!Task.isCancelled && observation == generation
	}

	/// Keeps the selection on a process the server still reports, so the log pane never
	/// points at a name that vanished across a reconnect.
	private func reconcileSelection() {
		if let selection, statesByName[selection] != nil { return }
		selection = processes.first?.name
	}

	// A process's configuration is fixed for the life of the project, so this runs
	// once per connection rather than per state event.
	private func loadConfigurations(for names: [String]) async -> [String: ProcessConfiguration] {
		await withTaskGroup(of: (String, ProcessConfiguration?).self) { group in
			for name in names {
				group.addTask { [client] in
					(name, try? await client.configuration(for: name))
				}
			}

			var configurations: [String: ProcessConfiguration] = [:]
			for await (name, configuration) in group {
				configurations[name] = configuration
			}
			return configurations
		}
	}
}
