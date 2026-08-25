import Foundation
import Observation

public enum StackPower: Sendable, Equatable {
	case canStart
	case canStop
	case unavailable
}

/// What the window is asking the user to confirm. Every question goes through one
/// target, so only one can ever be in flight.
public enum ConfirmTarget: Sendable, Equatable {
	case stopStack(promised: [String])
	case stopProject(String, promised: [String])
	/// Carries the server the question was asked about, so the answer cannot land on another.
	case stopServer(identity: Int)
	case startProject(String, missing: [String])

	/// Starting is the only one of these that does not take something away.
	public var isDestructive: Bool {
		if case .startProject = self { return false }
		return true
	}
}

public enum ConnectionState: Sendable, Equatable {
	case connecting
	case connected
	case disconnected(reason: String)
}

/// A question and the moment it was asked. An answer captured before the work was
/// abandoned cannot be acted on afterwards.
public struct Confirmation: Sendable, Equatable {
	public let target: ConfirmTarget
	let epoch: Int
}

@MainActor
@Observable
public final class StackViewModel {
	public private(set) var connection: ConnectionState = .connecting
	public private(set) var project: ProjectState?
	public private(set) var lastError: String?

	/// The row the list and the log pane share. Owned here so the menu bar can act on it.
	public var selection: String?

	/// The project the sidebar has selected.
	public private(set) var selectedProject: String?

	/// What the window is asking the user to confirm, if anything. Owned here because the
	/// toolbar button, the menu bar and the sidebar all raise it.
	public var confirmation: Confirmation?

	public private(set) var isChangingStack = false

	/// Whether every process's project is known. The server answers for each process
	/// separately, and one refusal leaves that process out of the grouping, where a
	/// project action would pass over it without saying so.
	public private(set) var isGroupingComplete = true

	public var runningProcesses: [ProcessState] {
		processes.filter(\.canStop)
	}

	public var startableProcesses: [ProcessState] {
		processes.filter(\.isStartable)
	}

	/// Which way the power button points.
	public var power: StackPower {
		if !runningProcesses.isEmpty { return .canStop }
		return startableProcesses.isEmpty ? .unavailable : .canStart
	}

	/// Whether the server can act on the power button right now. A group action and a
	/// single process's own action never overlap, in either direction, so neither can
	/// send a second request for a process the other is already asking about.
	public var canChangePower: Bool {
		connection == .connected && !isChangingStack && busy.isEmpty && power != .unavailable
	}

	/// The power button reaches the whole stack while the window shows one project, so
	/// the confirmation says how far the stop goes.
	public func question(for target: ConfirmTarget) -> String {
		switch target {
		case .stopStack(let promised):
			// Read from what the question promised, so the words cannot drift from what
			// answering it will actually do while it sits on screen.
			let label = Self.runningLabel(promised.count)
			let projectCount = Set(promised.map { projectsByProcess[$0] ?? ProcessGrouping.ungrouped }).count

			return projectCount > 1 ? "Stop \(label) across \(projectCount) projects?" : "Stop \(label)?"
		case .stopProject(let name, let promised):
			return "Stop \(Self.runningLabel(promised.count)) in \(name)?"
		case .stopServer:
			// The server can be ours to stop while the app has no list of what it is
			// running, and a question that then said nothing was running would understate it.
			guard connection == .connected else {
				return "Stop the server and every process it is running?"
			}

			let count = runningProcesses.count

			return count == 0 ? "Stop the server?" : "Stop the server and \(Self.runningLabel(count))?"
		case .startProject(let name, let missing):
			let named = missing.map { "\($0) in \(projectsByProcess[$0] ?? ProcessGrouping.ungrouped)" }
			let verb = named.count == 1 ? "is" : "are"

			return "\(name) depends on \(named.joined(separator: ", ")), which \(verb) not running. Start \(name) anyway?"
		}
	}

	/// What the button that answers the question says.
	public func answer(for target: ConfirmTarget) -> String {
		switch target {
		case .stopStack: "Stop the stack"
		case .stopProject(let name, _): "Stop \(name)"
		case .stopServer: "Stop the server"
		case .startProject(let name, _): "Start \(name)"
		}
	}

	private static func runningLabel(_ count: Int) -> String {
		count == 1 ? "1 running process" : "\(count) running processes"
	}

	/// Stopping asks first because it is destructive; starting does not.
	public func togglePower() {
		guard canChangePower else { return }

		switch power {
		case .canStop: ask(.stopStack(promised: runningProcesses.map(\.name).sorted()))
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

	public var projects: [ProjectGroup] {
		ProcessGrouping.projects(for: processes, projects: projectsByProcess)
	}

	public var visibleProcesses: [ProcessState] {
		selectedProject.map(processes(in:)) ?? []
	}

	public var sections: [StackSection] {
		ProcessGrouping.sections(for: visibleProcesses, kinds: kinds)
	}

	public func select(project: String) {
		guard project != selectedProject else { return }

		selectedProject = project
		reconcileSelection()
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

	public var configURLs: [URL] {
		(project?.configFiles ?? []).map { URL(fileURLWithPath: $0) }
	}

	public var usage: ResourceUsage {
		ResourceUsage.total(of: processes)
	}

	private var groupingError: String?
	private var actionEpoch = 0
	private var connectedAddress: ServerAddress?
	private var adopting: Set<String> = []
	private var busy: Set<String> = []
	private var statesByName: [String: ProcessState] = [:]
	private var configurations: [String: ProcessConfiguration] = [:]

	private var projectsByProcess: [String: String] = [:]
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
		// Nothing is connected now, so asking for the address that was refused, or for the
		// one before it, has to reconnect rather than be taken for where we already are.
		connectedAddress = nil
		connection = .disconnected(reason: reason)
	}

	/// Points the view model at a different server and starts over. Being handed a client
	/// for the address it is already on is another window, not another server, so it keeps
	/// what is open and what is under way.
	public func use(_ client: any ProcessComposeClient, at address: ServerAddress? = nil) {
		if let address, address == connectedAddress { return }

		connectedAddress = address
		generation += 1
		self.client = client
		abandonActions()
		connection = .connecting
		statesByName = [:]
		project = nil
		lastError = nil
		connect()
	}

	/// Drops what was agreed to and what is already under way. A question was asked about
	/// the stack that was on screen, and a different server answers for a different one,
	/// even when it is reached at the same address.
	public func abandonActions() {
		actionEpoch += 1
		confirmation = nil
	}

	/// Raises a question, stamped with the moment it was asked.
	public func ask(_ target: ConfirmTarget) {
		confirmation = Confirmation(target: target, epoch: actionEpoch)
	}

	public func isBusy(_ name: String?) -> Bool {
		name.map(busy.contains) ?? false
	}

	public func canStart(_ name: String?) -> Bool {
		guard let name, let state = statesByName[name] else { return false }
		return state.canStart && !busy.contains(name) && !isChangingStack
	}

	public func canStop(_ name: String?) -> Bool {
		guard let name, let state = statesByName[name] else { return false }
		return state.canStop && !busy.contains(name) && !isChangingStack
	}

	public func startProcess(_ name: String) async {
		guard canStart(name) else { return refuse("start", name) }

		await act(on: name) { try await self.client.start(name) }
	}

	public func stopProcess(_ name: String) async {
		guard canStop(name) else { return refuse("stop", name) }

		await act(on: name) { try await self.client.stop(name) }
	}

	public func restartProcess(_ name: String) async {
		guard canStop(name) else { return refuse("restart", name) }

		await act(on: name) { try await self.client.restart(name) }
	}

	/// Starts every process the stack defines. Processes the config disabled stay off,
	/// because switching one of those on is a per-process decision made on its row.
	public func startStack() async {
		guard canChangePower else { return refuse("start", "the stack") }

		await applyToStack(
			touching: processes.map(\.name),
			stopping: false,
			failureVerb: "start",
			select: { self.startableProcesses.map(\.name) }
		) { client, name in
			try await client.start(name)
		}
	}

	public func stopStack(promised: [String]? = nil) async {
		guard canChangePower else { return refuse("stop", "the stack") }

		await applyToStack(
			touching: processes.map(\.name),
			stopping: true,
			failureVerb: "stop",
			validate: {
				guard let promised else { return nil }

				return self.runningProcesses.map(\.name).sorted() == promised
					? nil
					: "What is running changed while the question was open, so nothing was stopped"
			},
			select: { self.runningProcesses.map(\.name) }
		) { client, name in
			try await client.stop(name)
		}
	}

	/// The server is not this model's to stop, so `.stopServer` is the window's to dispatch.
	public func perform(_ confirmation: Confirmation) async {
		// The question was asked before this work was abandoned, so its answer is void.
		guard confirmation.epoch == actionEpoch else { return }

		switch confirmation.target {
		case .stopStack(let promised): await stopStack(promised: promised)
		case .stopProject(let name, let promised): await stopProject(name, promised: promised)
		case .startProject(let name, let missing): await startProject(name, promisedMissing: missing)
		case .stopServer: break
		}
	}

	/// Starting asks first only when the project would come up without something it
	/// depends on, since starting a process leaves its dependencies where they are.
	public func requestStartProject(_ name: String) {
		guard canStartProject(name) else { return refuse("start", name) }

		let missing = missingDependencies(startingProject: name)

		guard missing.isEmpty else {
			ask(.startProject(name, missing: missing))
			return
		}

		Task { await startProject(name) }
	}

	/// What the project depends on that this start will not bring up. Asking the server to
	/// start a process starts that process alone: process-compose v1.122.0 does not follow
	/// `depends_on` for a start, it only waits on the condition and carries on.
	public func missingDependencies(startingProject project: String) -> [String] {
		let starting = Set(startableProcesses(in: project).map(\.name))

		return closure(of: Array(starting))
			.subtracting(starting)
			.filter { statesByName[$0]?.isRunning != true }
			.sorted()
	}

	/// Everything a start would touch: the processes asked for, and whatever they depend
	/// on, all the way down.
	private func closure(of names: [String]) -> Set<String> {
		var reached: Set<String> = []
		var pending = names

		while let name = pending.popLast() {
			guard reached.insert(name).inserted else { continue }

			pending.append(contentsOf: configurations[name]?.dependsOn ?? [])
		}

		return reached
	}

	/// Starts a single project's processes, leaving every other project alone. The
	/// config's disabled processes stay off, as they do for the whole stack.
	public func startProject(_ name: String, promisedMissing: [String]? = nil) async {
		guard canStartProject(name) else { return refuse("start", name) }

		await applyToStack(
			touching: processes.map(\.name),
			stopping: false,
			failureVerb: "start",
			validate: {
				let missing = self.missingDependencies(startingProject: name)

				guard let promisedMissing else {
					guard !missing.isEmpty else { return nil }

					return "\(name) depends on \(missing.joined(separator: ", ")), which is not running, so nothing was started"
				}

				return missing == promisedMissing
					? nil
					: "What \(name) depends on changed while the question was open, so nothing was started"
			},
			select: { self.startableProcesses(in: name).map(\.name) }
		) { client, process in
			try await client.start(process)
		}
	}

	/// Raises the question, remembering exactly what it says it will stop.
	public func requestStopProject(_ name: String) {
		guard canStopProject(name) else { return refuse("stop", name) }

		ask(.stopProject(name, promised: stoppableProcesses(in: name).map(\.name).sorted()))
	}

	public func stopProject(_ name: String, promised: [String]? = nil) async {
		guard canStopProject(name) else { return refuse("stop", name) }

		await applyToStack(
			touching: processes.map(\.name),
			stopping: true,
			failureVerb: "stop",
			validate: {
				guard let promised else { return nil }

				return self.stoppableProcesses(in: name).map(\.name).sorted() == promised
					? nil
					: "What is running in \(name) changed while the question was open, so nothing was stopped"
			},
			select: { self.stoppableProcesses(in: name).map(\.name) }
		) { client, process in
			try await client.stop(process)
		}
	}

	/// A menu is drawn before it is chosen and a dialog is answered after it is asked, so
	/// a reconnect, or another action starting, can retire what was offered. Saying nothing
	/// happened beats half doing it.
	private func refuse(_ verb: String, _ subject: String) {
		lastError = "Did not \(verb) \(subject), because what it could do changed"
	}

	public func canStartProject(_ name: String) -> Bool {
		canAct(on: name) && !startableProcesses(in: name).isEmpty
	}

	public func canStopProject(_ name: String) -> Bool {
		canAct(on: name) && !stoppableProcesses(in: name).isEmpty
	}

	/// A project action reaches everything the grouping puts in that project, and a start
	/// reaches whatever those depend on as well, so it is only offered while the grouping
	/// accounts for every process and nothing anywhere is carrying a request of its own.
	private func canAct(on project: String) -> Bool {
		connection == .connected && !isChangingStack && isGroupingComplete && busy.isEmpty
	}

	private func processes(in project: String) -> [ProcessState] {
		projects.first { $0.name == project }?.processes ?? []
	}

	private func startableProcesses(in project: String) -> [ProcessState] {
		processes(in: project).filter(\.isStartable)
	}

	private func stoppableProcesses(in project: String) -> [ProcessState] {
		processes(in: project).filter(\.canStop)
	}

	/// Prerequisites first. Asking the server to start a process starts that one alone, so
	/// a bulk action has to send them in an order that stands up on its own; a stop takes
	/// the same order backwards. A dependency cycle keeps whatever order it is walked in.
	private func inDependencyOrder(_ names: [String]) -> [String] {
		let wanted = Set(names)
		var ordered: [String] = []
		var seen: Set<String> = []

		func visit(_ name: String) {
			guard wanted.contains(name), seen.insert(name).inserted else { return }

			for dependency in configurations[name]?.dependsOn ?? [] { visit(dependency) }

			ordered.append(name)
		}

		for name in names { visit(name) }

		return ordered
	}

	// One process at a time, in the order given: the server starts only the process it is
	// asked for, so firing the whole list at once would race their dependencies.
	/// One bulk action from end to end. It takes the floor before it does anything that
	/// waits, so nothing else can slip in behind an await; it re-reads what it is about to
	/// touch from the server it started on; and it sends the requests in dependency order,
	/// passing over anything whose prerequisite failed.
	private func applyToStack(
		touching members: [String],
		stopping: Bool,
		failureVerb: String,
		validate: () -> String? = { nil },
		select: () -> [String],
		_ operation: (any ProcessComposeClient, String) async throws -> Void
	) async {
		let client = self.client
		let mine = generation
		let epoch = actionEpoch

		isChangingStack = true
		defer { isChangingStack = false }

		guard await refreshConfigurations(for: members, from: client, observation: mine, epoch: epoch) else { return }
		guard epoch == actionEpoch else { return }

		// What was true when the action was offered is checked again against what the
		// server just said, not against the cache the decision was taken from.
		if let complaint = validate() {
			lastError = complaint
			return
		}

		let ordered = inDependencyOrder(select())
		let names = stopping ? ordered.reversed().map { $0 } : ordered

		guard !names.isEmpty else { return }

		// `select` runs after the read, and the stream can bring a process in meanwhile.
		// Anything that was not read has no dependency data this action can stand on.
		guard Set(names).isSubset(of: Set(members)) else {
			lastError = "The stack changed while it was being read, so nothing was changed"
			return
		}

		let blockedBy = blockers(among: names, stopping: stopping)
		var failures: [String] = []
		var skipped: [String] = []

		for name in names {
			guard mine == generation, epoch == actionEpoch else { return }

			// Ordering only holds while everything before it worked: a process whose
			// prerequisite never started would come up without it.
			if let blockers = blockedBy[name],
				!blockers.isDisjoint(with: Set(failures).union(skipped)) {
				skipped.append(name)
				continue
			}

			busy.insert(name)
			do {
				try await operation(client, name)
			} catch {
				failures.append(name)
			}
			busy.remove(name)
		}

		var trouble: [String] = []

		if !failures.isEmpty {
			trouble.append("Could not \(failureVerb) \(failures.joined(separator: ", "))")
		}
		if !skipped.isEmpty {
			trouble.append("did not \(failureVerb) \(skipped.joined(separator: ", "))")
		}

		lastError = trouble.isEmpty ? groupingError : trouble.joined(separator: "; ")
	}

	/// Dependency order is only as good as the configurations it was read from, and a stack
	/// can be reloaded while the app stays connected, so what an action is about to touch is
	/// read again first. A read it cannot complete stops the action rather than falling back
	/// on what the cache happens to still hold.
	private func refreshConfigurations(
		for names: [String],
		from client: any ProcessComposeClient,
		observation mine: Int,
		epoch: Int
	) async -> Bool {
		let loaded = await loadConfigurations(for: names, from: client)

		// Nothing this read found is published once the work it was for has been abandoned,
		// or the sidebar could be moved by an action that is about to be refused anyway.
		guard mine == generation, epoch == actionEpoch else { return false }

		let unread = names.filter { loaded[$0] == nil }.sorted()

		guard unread.isEmpty else {
			lastError = "Could not read the configuration for \(unread.joined(separator: ", ")), so nothing was changed"
			return false
		}

		for (name, configuration) in loaded {
			configurations[name] = configuration
			projectsByProcess[name] = ProcessGrouping.project(forWorkingDir: configuration.workingDir)
		}

		recomputeGrouping()

		// The re-read can move a process to another project, so the sidebar and the row
		// selection settle here the same way they do for the processes a connection starts
		// with and for one the stream brings in.
		reconcileProject()
		reconcileSelection()

		return true
	}

	/// What must not be acted on once something else has failed: for a start, whatever a
	/// process depends on; for a stop, whatever depends on it.
	private func blockers(among names: [String], stopping: Bool) -> [String: Set<String>] {
		let wanted = Set(names)
		var blockers: [String: Set<String>] = [:]

		for name in names {
			for dependency in configurations[name]?.dependsOn ?? [] where wanted.contains(dependency) {
				if stopping {
					blockers[dependency, default: []].insert(name)
				} else {
					blockers[name, default: []].insert(dependency)
				}
			}
		}

		return blockers
	}

	public func dismissError() {
		lastError = nil
	}

	private func act(on name: String, _ operation: () async throws -> Void) async {
		busy.insert(name)
		defer { busy.remove(name) }

		do {
			try await operation()
			// A grouping that is still short outlives this action, so its message stands.
			lastError = groupingError
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
			async let loaded = loadConfigurations(for: snapshot.map(\.name), from: client)
			let loadedProject = await state
			let loadedConfigurations = await loaded
			guard isCurrent(mine) else { return }

			project = loadedProject
			projectReadAt = loadedProject == nil ? nil : now()
			refreshUptime()
			configurations = loadedConfigurations
			projectsByProcess = loadedConfigurations.compactMapValues {
				ProcessGrouping.project(forWorkingDir: $0.workingDir)
			}
			recomputeGrouping()
			reconcileProject()
			reconcileSelection()
			connection = .connected

			for try await event in client.stateEvents() {
				guard isCurrent(mine) else { return }

				let name = event.state.name
				statesByName[name] = event.state

				// Keyed on the missing configuration rather than on the process being new, so
				// a read that failed is tried again the next time the process is heard from.
				guard configurations[name] == nil, !adopting.contains(name) else { continue }

				adopting.insert(name)
				recomputeGrouping()

				// The read is left to run on its own: a configuration request that hangs must
				// not hold up the state changes queued behind it on the stream.
				Task { [weak self] in await self?.adopt(name, observation: mine) }
			}

			guard isCurrent(mine) else { return }
			disconnect(reason: ProcessComposeError.streamClosed.localizedDescription)
		} catch is CancellationError {
			return
		} catch {
			guard isCurrent(mine) else { return }
			disconnect(reason: error.localizedDescription)
		}
	}

	/// The project belongs to the server that reported it, so its name, version and uptime
	/// go with the connection rather than ageing on screen.
	private func disconnect(reason: String) {
		project = nil
		projectReadAt = nil
		uptime = nil
		connection = .disconnected(reason: reason)
	}

	/// Every await in `observe` is a point where the connection can be cancelled or
	/// replaced. Cancellation ends a stream normally rather than throwing, and `try?`
	/// swallows it outright, so an abandoned attempt would otherwise publish over the
	/// connection that replaced it.
	private func isCurrent(_ observation: Int) -> Bool {
		!Task.isCancelled && observation == generation
	}

	/// Keeps the sidebar on a project the stack still defines. The projects are read
	/// from the configurations, so this runs once they have loaded.
	private func reconcileProject() {
		let known = projects.map(\.name)
		if let selectedProject, known.contains(selectedProject) { return }

		// Falling back to another project is a switch, and a row selection never survives
		// one: otherwise it would follow a process into a project nobody chose.
		if selectedProject != nil { selection = nil }

		selectedProject = known.first
	}

	/// The one place that decides the selection is a row the list shows, so it survives
	/// neither a process the server dropped nor a switch to another project.
	private func reconcileSelection() {
		guard let selection, !visibleProcesses.contains(where: { $0.name == selection }) else { return }
		self.selection = nil
	}

	/// A process belongs to a project only once its configuration has been read, so the
	/// grouping is complete when every process the app knows about has one.
	private func recomputeGrouping() {
		let unread = statesByName.keys.filter { configurations[$0] == nil }.sorted()

		isGroupingComplete = unread.isEmpty

		guard !unread.isEmpty else {
			// Only the message this put there is cleared, so a failure from anywhere else
			// still stands, and so does one the user has already dismissed.
			if lastError == groupingError { lastError = nil }
			groupingError = nil
			return
		}

		groupingError = "Could not read the configuration for \(unread.joined(separator: ", ")), so project actions stay off"
		lastError = groupingError
	}

	/// The stream can introduce a process the connection never read a configuration for,
	/// which leaves it in no project. Project actions are withheld from the moment it
	/// appears until it has been placed.
	private func adopt(_ name: String, observation mine: Int) async {
		let loaded = await loadConfigurations(for: [name], from: client)

		adopting.remove(name)

		guard isCurrent(mine) else { return }

		if let configuration = loaded[name] {
			configurations[name] = configuration
			projectsByProcess[name] = ProcessGrouping.project(forWorkingDir: configuration.workingDir)
		}

		recomputeGrouping()

		// A process arriving can be the first of its project, and the sidebar settles the
		// same way here as it does for the processes the connection started with.
		reconcileProject()
		reconcileSelection()
	}

	// A process's configuration is fixed for the life of the project, so this runs
	// once per connection rather than per state event.
	private func loadConfigurations(
		for names: [String],
		from client: any ProcessComposeClient
	) async -> [String: ProcessConfiguration] {
		var loaded = await readConfigurations(for: names, from: client)

		// Each configuration is a request of its own, so a single blip would otherwise keep
		// a process out of the grouping for the whole connection, with no second chance
		// until something else forces a reconnect.
		let unread = names.filter { loaded[$0] == nil }

		guard !unread.isEmpty else { return loaded }

		for (name, configuration) in await readConfigurations(for: unread, from: client) {
			loaded[name] = configuration
		}

		return loaded
	}

	private func readConfigurations(
		for names: [String],
		from client: any ProcessComposeClient
	) async -> [String: ProcessConfiguration] {
		await withTaskGroup(of: (String, ProcessConfiguration?).self) { group in
			for name in names {
				group.addTask {
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
