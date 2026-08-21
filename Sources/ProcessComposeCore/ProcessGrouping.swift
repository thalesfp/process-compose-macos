import Foundation

/// The subset of a process's config that the app reads.
public struct ProcessConfiguration: Decodable, Sendable, Hashable {
	public let workingDir: String?
	public let hasWatcher: Bool
	public let restartsAutomatically: Bool

	public init(workingDir: String?, hasWatcher: Bool = false, restartsAutomatically: Bool = false) {
		self.workingDir = workingDir
		self.hasWatcher = hasWatcher
		self.restartsAutomatically = restartsAutomatically
	}

	enum CodingKeys: String, CodingKey {
		case workingDir, watch, restartPolicy
	}

	private struct RestartPolicy: Decodable {
		let restart: Int?
	}

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		workingDir = try c.decodeIfPresent(String.self, forKey: .workingDir)
		hasWatcher = c.contains(.watch)
		// The server encodes the policy as an enum ordinal, and omits it entirely
		// for the default, so any value at all means the process is kept alive.
		let policy = try c.decodeIfPresent(RestartPolicy.self, forKey: .restartPolicy)
		restartsAutomatically = (policy?.restart ?? 0) != 0
	}
}

/// What a process is for. process-compose has no such field: a service is one that
/// stays up, a task is one that runs to completion, and only its behaviour says which.
public enum ProcessKind: String, Sendable, Hashable, CaseIterable {
	case service
	case task

	public var label: String {
		switch self {
		case .service: "services"
		case .task: "tasks"
		}
	}

	public static func of(state: ProcessState, configuration: ProcessConfiguration?) -> ProcessKind {
		// A watcher on a command that is not kept alive re-runs it on every change,
		// which is a task. A watched process that restarts itself is still a service.
		if let configuration, configuration.hasWatcher, !configuration.restartsAutomatically {
			return .task
		}

		switch state.status {
		case .completed, .watching: return .task
		default: return .service
		}
	}
}

public struct ProjectGroup: Sendable, Identifiable, Hashable {
	public let name: String
	public let processes: [ProcessState]

	public var id: String { name }
	public var runningCount: Int { processes.filter(\.canStop).count }
	public var processCount: Int { processes.count }
}

/// One List section: the processes of a single kind inside one namespace, plus the
/// headings that belong above it.
public struct StackSection: Sendable, Identifiable, Hashable {
	public let namespace: String
	public let kind: ProcessKind
	public let processes: [ProcessState]
	public let isFirstInNamespace: Bool
	/// A namespace of only services needs no role heading; the rows are the services.
	public let showsKind: Bool

	public var id: String { "\(namespace)/\(kind.rawValue)" }
}

public enum ProcessGrouping {
	static let ungrouped = "other"

	/// The repo a process runs in, taken from the first component of its working
	/// directory. Absolute paths have no discoverable repo root, so they stay ungrouped.
	public static func project(forWorkingDir workingDir: String?) -> String? {
		guard var path = workingDir, !path.isEmpty, !path.hasPrefix("/") else { return nil }

		while path.hasPrefix("./") {
			path.removeFirst(2)
		}

		let first = path.split(separator: "/").first.map(String.init)

		return first.flatMap { $0 == "." || $0 == ".." ? nil : $0 }
	}

	/// The sidebar, one row per project, with the catch-all last.
	public static func projects(
		for states: [ProcessState],
		projects: [String: String]
	) -> [ProjectGroup] {
		Dictionary(grouping: states) { projects[$0.name] ?? ungrouped }
			.map { ProjectGroup(name: $0.key, processes: $0.value) }
			.sorted { left, right in
				// The catch-all sinks to the bottom; real projects sort by name.
				if left.name == ungrouped || right.name == ungrouped { return right.name == ungrouped }
				return left.name < right.name
			}
	}

	/// Flattens namespace and kind into one section per row-group, so a heading never
	/// shares a List row with the processes under it.
	public static func sections(
		for states: [ProcessState],
		kinds: [String: ProcessKind]
	) -> [StackSection] {
		var sections: [StackSection] = []

		for stack in stacks(for: states) {
			let byKind = Dictionary(grouping: stack.processes) { kinds[$0.name] ?? .service }
			let present = ProcessKind.allCases.filter { byKind[$0]?.isEmpty == false }
			let showsKind = present.count > 1 || present == [.task]
			var isFirstInNamespace = true

			for kind in present {
				sections.append(
					StackSection(
						namespace: stack.namespace,
						kind: kind,
						processes: byKind[kind] ?? [],
						isFirstInNamespace: isFirstInNamespace,
						showsKind: showsKind
					)
				)
				isFirstInNamespace = false
			}
		}

		return sections
	}

	private static func stacks(
		for states: [ProcessState]
	) -> [(namespace: String, processes: [ProcessState])] {
		Dictionary(grouping: states, by: \.namespace)
			.sorted { $0.key < $1.key }
			.map { (namespace: $0.key, processes: $0.value.sorted { $0.name < $1.name }) }
	}
}
