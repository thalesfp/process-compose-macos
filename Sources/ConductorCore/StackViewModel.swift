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
	public private(set) var busy: Set<String> = []
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

	/// Which way the power button points. Whether the server can act on it is a
	/// separate question the view answers from `connection`.
	public var power: StackPower {
		if !runningProcesses.isEmpty { return .canStop }
		return startableProcesses.isEmpty ? .unavailable : .canStart
	}

	public var selectedProcess: ProcessState? {
		selection.flatMap { statesByName[$0] }
	}

	public var namespaces: [String] {
		Array(Set(statesByName.values.map(\.namespace))).sorted()
	}

	public var processes: [ProcessState] {
		statesByName.values.sorted { left, right in
			left.namespace == right.namespace
				? left.name < right.name
				: left.namespace < right.namespace
		}
	}

	public func processes(in namespace: String) -> [ProcessState] {
		processes.filter { $0.namespace == namespace }
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

	public func kind(of state: ProcessState) -> ProcessKind {
		ProcessKind.of(state: state, configuration: configurations[state.name])
	}

	public var usage: ResourceUsage {
		ResourceUsage.total(of: processes)
	}

	private var statesByName: [String: ProcessState] = [:]
	private var configurations: [String: ProcessConfiguration] = [:]

	private var projectsByProcess: [String: String] {
		configurations.compactMapValues { ProcessGrouping.project(forWorkingDir: $0.workingDir) }
	}
	private var client: any ProcessComposeClient
	private let retryDelay: Duration
	private var streamTask: Task<Void, Never>?

	public init(client: any ProcessComposeClient, retryDelay: Duration = .seconds(2)) {
		self.client = client
		self.retryDelay = retryDelay
	}

	public func connect() {
		streamTask?.cancel()
		streamTask = Task { [weak self] in
			while !Task.isCancelled {
				guard let self else { return }
				await self.observe()
				guard !Task.isCancelled else { return }
				try? await Task.sleep(for: self.retryDelay)
			}
		}
	}

	public func disconnect() {
		streamTask?.cancel()
		streamTask = nil
	}

	/// Points the view model at a different server and starts over.
	public func use(_ client: any ProcessComposeClient) {
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
		do {
			let snapshot = try await client.processes()
			statesByName = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.name, $0) })
			project = try? await client.projectState()
			configurations = await loadConfigurations(for: snapshot.map(\.name))
			reconcileSelection()
			connection = .connected

			for try await event in client.stateEvents() {
				statesByName[event.state.name] = event.state
			}

			connection = .disconnected(reason: ProcessComposeError.streamClosed.localizedDescription)
		} catch is CancellationError {
			return
		} catch {
			connection = .disconnected(reason: error.localizedDescription)
		}
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
