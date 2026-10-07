import Foundation

public struct ProcessState: Decodable, Sendable, Identifiable, Hashable {
	public var id: String { name }

	public let name: String
	public let namespace: String
	public let status: ProcessStatus
	public let readiness: String
	public let hasReadinessProbe: Bool
	public let restarts: Int
	public let exitCode: Int
	public let memoryBytes: Int64
	public let cpuPercent: Double
	public let isRunning: Bool
	public let isWatched: Bool
	public let watchTriggerPath: String?
	public let ageNanoseconds: Int64

	public var age: Duration { .nanoseconds(ageNanoseconds) }

	public var isReady: Bool { readiness == "Ready" }

	public init(
		name: String,
		namespace: String = "default",
		status: ProcessStatus,
		readiness: String = "-",
		hasReadinessProbe: Bool = false,
		restarts: Int = 0,
		exitCode: Int = 0,
		memoryBytes: Int64 = 0,
		cpuPercent: Double = 0,
		isRunning: Bool = false,
		isWatched: Bool = false,
		watchTriggerPath: String? = nil,
		ageNanoseconds: Int64 = 0
	) {
		self.name = name
		self.namespace = namespace
		self.status = status
		self.readiness = readiness
		self.hasReadinessProbe = hasReadinessProbe
		self.restarts = restarts
		self.exitCode = exitCode
		self.memoryBytes = memoryBytes
		self.cpuPercent = cpuPercent
		self.isRunning = isRunning
		self.isWatched = isWatched
		self.watchTriggerPath = watchTriggerPath
		self.ageNanoseconds = ageNanoseconds
	}

	enum CodingKeys: String, CodingKey {
		case name, namespace, status, restarts, mem, cpu, age
		case readiness = "is_ready"
		case hasReadinessProbe = "has_ready_probe"
		case exitCode = "exit_code"
		case isRunning = "is_running"
		case isWatched = "is_watched"
		case watchTriggerPath = "watch_trigger_path"
	}

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		name = try c.decode(String.self, forKey: .name)
		namespace = try Self.decodeNamespace(from: c)
		status = ProcessStatus(rawValue: try c.decode(String.self, forKey: .status))
		readiness = try c.decodeIfPresent(String.self, forKey: .readiness) ?? "-"
		hasReadinessProbe = try c.decodeIfPresent(Bool.self, forKey: .hasReadinessProbe) ?? false
		restarts = try c.decodeIfPresent(Int.self, forKey: .restarts) ?? 0
		exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode) ?? 0
		memoryBytes = try c.decodeIfPresent(Int64.self, forKey: .mem) ?? 0
		cpuPercent = try c.decodeIfPresent(Double.self, forKey: .cpu) ?? 0
		// The state socket announces a restarted process as Running while its is_running
		// flag is still false, and sends no later event to correct it.
		let reportedRunning = try c.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
		isRunning = reportedRunning || status == .running
		isWatched = try c.decodeIfPresent(Bool.self, forKey: .isWatched) ?? false
		watchTriggerPath = try c.decodeIfPresent(String.self, forKey: .watchTriggerPath)
		ageNanoseconds = try c.decodeIfPresent(Int64.self, forKey: .age) ?? 0
	}

	// The server's Go type is a slice tagged as a string, so accept either shape.
	private static func decodeNamespace(from c: KeyedDecodingContainer<CodingKeys>) throws -> String {
		if let single = try? c.decode(String.self, forKey: .namespace) {
			return single
		}
		let many = try c.decodeIfPresent([String].self, forKey: .namespace) ?? []
		return many.first ?? "default"
	}
}

public enum ProcessStatus: Sendable, Hashable {
	case running
	case pending
	case restarting
	case terminating
	case completed
	case skipped
	case disabled
	case watching
	case error
	case other(String)

	public init(rawValue: String) {
		switch rawValue {
		case "Running": self = .running
		case "Pending": self = .pending
		case "Restarting": self = .restarting
		case "Terminating": self = .terminating
		case "Completed": self = .completed
		case "Skipped": self = .skipped
		case "Disabled": self = .disabled
		case "Watching": self = .watching
		case "Error": self = .error
		default: self = .other(rawValue)
		}
	}

	public var rawValue: String {
		switch self {
		case .running: "Running"
		case .pending: "Pending"
		case .restarting: "Restarting"
		case .terminating: "Terminating"
		case .completed: "Completed"
		case .skipped: "Skipped"
		case .disabled: "Disabled"
		case .watching: "Watching"
		case .error: "Error"
		case .other(let raw): raw
		}
	}
}

public enum ProcessIndicator: Sendable, Hashable {
	case healthy
	case running
	case waiting
	case watching
	case idle
	case failed
}

extension ProcessState {
	public var indicator: ProcessIndicator {
		switch status {
		case .running:
			hasReadinessProbe ? (isReady ? .healthy : .waiting) : .running
		case .pending, .restarting, .terminating:
			.waiting
		case .watching:
			.watching
		case .completed:
			exitedWithError ? .failed : .idle
		case .disabled, .skipped:
			.idle
		case .error:
			.failed
		case .other:
			.idle
		}
	}

	/// Go reports -1 for a process ended by a signal, which is how a stop ends it.
	public var exitedWithError: Bool { exitCode > 0 }

	/// True once the process has actually finished a run, so a task that has never
	/// started does not read as a clean exit.
	public var hasRun: Bool {
		switch status {
		case .completed, .watching: true
		default: false
		}
	}

	/// The server answers 400 "already running" for a process it has already scheduled,
	/// so Pending, Restarting and Terminating are not offers the app can make.
	public var canStart: Bool {
		switch status {
		case .running, .pending, .restarting, .terminating, .watching: false
		case .completed, .skipped, .disabled, .error, .other: !isRunning
		}
	}
	public var canStop: Bool { isRunning }

	/// Startable and not switched off by the config. Turning a disabled process on is a
	/// decision made on its own row, so nothing that starts a group of them includes it.
	public var isStartable: Bool { canStart && status != .disabled }
}

public struct ProcessStateEvent: Decodable, Sendable {
	public let state: ProcessState

	public init(state: ProcessState) {
		self.state = state
	}
}

public struct ProjectState: Decodable, Sendable, Hashable {
	public let projectName: String
	public let version: String
	public let processNum: Int
	public let runningProcessNum: Int
	public let upTimeNanoseconds: Int64
	public let configFiles: [String]?

	public init(
		projectName: String,
		version: String,
		processNum: Int,
		runningProcessNum: Int,
		upTimeNanoseconds: Int64,
		configFiles: [String]?
	) {
		self.projectName = projectName
		self.version = version
		self.processNum = processNum
		self.runningProcessNum = runningProcessNum
		self.upTimeNanoseconds = upTimeNanoseconds
		self.configFiles = configFiles
	}

	enum CodingKeys: String, CodingKey {
		case projectName, version, processNum, runningProcessNum
		case upTimeNanoseconds = "upTime"
		case configFiles = "fileNames"
	}

	public var upTime: Duration { .nanoseconds(upTimeNanoseconds) }
}
