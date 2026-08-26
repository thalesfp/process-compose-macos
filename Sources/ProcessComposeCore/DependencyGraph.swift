/// The `depends_on` edges a stack's configurations describe, and the three questions a
/// bulk action asks of them. Nothing here reads live process state or reaches a server,
/// so the ordering rules can be exercised on their own.
public struct DependencyGraph: Sendable, Equatable {
	private let dependencies: [String: [String]]

	public init(_ configurations: [String: ProcessConfiguration]) {
		dependencies = configurations.mapValues(\.dependsOn)
	}

	/// Prerequisites first. Asking the server to start a process starts that one alone, so
	/// a bulk action has to send them in an order that stands up on its own; a stop takes
	/// the same order backwards. Only the names being acted on are visited, so a dependency
	/// outside the set does not pull itself in, and a cycle keeps whatever order it is
	/// walked in rather than recurring.
	public func inDependencyOrder(_ names: [String]) -> [String] {
		let wanted = Set(names)
		var ordered: [String] = []
		var seen: Set<String> = []

		func visit(_ name: String) {
			guard wanted.contains(name), seen.insert(name).inserted else { return }

			for dependency in dependencies[name] ?? [] { visit(dependency) }

			ordered.append(name)
		}

		for name in names { visit(name) }

		return ordered
	}

	/// What must not be acted on once something else has failed: for a start, whatever a
	/// process depends on; for a stop, whatever depends on it.
	public func blockers(among names: [String], stopping: Bool) -> [String: Set<String>] {
		let wanted = Set(names)
		var blockers: [String: Set<String>] = [:]

		for name in names {
			for dependency in dependencies[name] ?? [] where wanted.contains(dependency) {
				if stopping {
					blockers[dependency, default: []].insert(name)
				} else {
					blockers[name, default: []].insert(dependency)
				}
			}
		}

		return blockers
	}

	/// Everything a start would touch: the processes asked for, and whatever they depend
	/// on, all the way down.
	public func closure(of names: [String]) -> Set<String> {
		var reached: Set<String> = []
		var pending = names

		while let name = pending.popLast() {
			guard reached.insert(name).inserted else { continue }

			pending.append(contentsOf: dependencies[name] ?? [])
		}

		return reached
	}
}
