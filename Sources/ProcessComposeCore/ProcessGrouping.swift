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

public struct StackGroup: Sendable, Identifiable, Hashable {
	public let name: String
	public let processes: [ProcessState]

	public var id: String { name }
}

public struct ProjectGroup: Sendable, Identifiable, Hashable {
	/// Nil when every process belongs to one project, so the view drops the level.
	public let name: String?
	public let stacks: [StackGroup]

	public var id: String { name ?? "" }
}

/// One List section: the processes of a single kind inside one namespace, plus the
/// headings that belong above it.
public struct StackSection: Sendable, Identifiable, Hashable {
	public let project: String?
	public let namespace: String
	public let kind: ProcessKind
	public let processes: [ProcessState]
	public let isFirstInProject: Bool
	public let isFirstInNamespace: Bool
	/// A namespace of only services needs no role heading; the rows are the services.
	public let showsKind: Bool

	public var id: String { "\(project ?? "")/\(namespace)/\(kind.rawValue)" }
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

	/// Groups by project, then by namespace. A run whose processes all share one
	/// project keeps a single level, so this stays useful for any other project.
	public static func groups(
		for states: [ProcessState],
		projects: [String: String]
	) -> [ProjectGroup] {
		let named = Set(states.compactMap { projects[$0.name] })

		guard named.count > 1 else {
			return [ProjectGroup(name: nil, stacks: stacks(for: states))]
		}

		let byProject = Dictionary(grouping: states) { projects[$0.name] ?? ungrouped }

		return byProject.keys.sorted { left, right in
			// The catch-all sinks to the bottom; real projects sort by name.
			if left == ungrouped || right == ungrouped { return right == ungrouped }
			return left < right
		}
		.map { ProjectGroup(name: $0, stacks: stacks(for: byProject[$0] ?? [])) }
	}

	/// Flattens project, namespace and kind into one section per row-group, so a
	/// heading never shares a List row with the processes under it.
	public static func sections(
		for groups: [ProjectGroup],
		kinds: [String: ProcessKind]
	) -> [StackSection] {
		var sections: [StackSection] = []

		for group in groups {
			var isFirstInProject = true

			for stack in group.stacks {
				let byKind = Dictionary(grouping: stack.processes) { kinds[$0.name] ?? .service }
				let present = ProcessKind.allCases.filter { byKind[$0]?.isEmpty == false }
				let showsKind = present.count > 1 || present == [.task]
				var isFirstInNamespace = true

				for kind in present {
					sections.append(
						StackSection(
							project: group.name,
							namespace: stack.name,
							kind: kind,
							processes: byKind[kind] ?? [],
							isFirstInProject: isFirstInProject,
							isFirstInNamespace: isFirstInNamespace,
							showsKind: showsKind
						)
					)
					isFirstInProject = false
					isFirstInNamespace = false
				}
			}
		}

		return sections
	}

	private static func stacks(for states: [ProcessState]) -> [StackGroup] {
		Dictionary(grouping: states, by: \.namespace)
			.sorted { $0.key < $1.key }
			.map { StackGroup(name: $0.key, processes: $0.value.sorted { $0.name < $1.name }) }
	}
}
