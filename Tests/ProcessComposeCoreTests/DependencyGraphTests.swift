import Testing

@testable import ProcessComposeCore

private func graph(_ edges: [String: [String]]) -> DependencyGraph {
	DependencyGraph(edges.mapValues { ProcessConfiguration(workingDir: nil, dependsOn: $0) })
}

struct DependencyGraphTests {
	@Test("sends a process after everything it depends on")
	func ordersPrerequisitesFirst() {
		let subject = graph(["api": ["db"], "db": ["cache"], "cache": []])

		let ordered = subject.inDependencyOrder(["api", "db", "cache"])

		#expect(ordered == ["cache", "db", "api"])
	}

	@Test("leaves out a dependency the action was not asked to touch")
	func staysInsideTheRequestedSet() {
		let subject = graph(["api": ["db"], "db": []])

		let ordered = subject.inDependencyOrder(["api"])

		#expect(ordered == ["api"])
	}

	@Test("returns an order for a stack whose config describes a cycle")
	func survivesACycle() {
		let subject = graph(["api": ["db"], "db": ["api"]])

		let ordered = subject.inDependencyOrder(["api", "db"])

		#expect(Set(ordered) == ["api", "db"])
		#expect(ordered.count == 2)
	}

	@Test("holds a process back when what it depends on failed to start")
	func blocksAStartOnItsPrerequisite() {
		let subject = graph(["api": ["db"], "db": []])

		let blocked = subject.blockers(among: ["db", "api"], stopping: false)

		#expect(blocked["api"] == ["db"])
		#expect(blocked["db"] == nil)
	}

	@Test("holds a dependency back when what depends on it failed to stop")
	func blocksAStopOnItsDependent() {
		let subject = graph(["api": ["db"], "db": []])

		let blocked = subject.blockers(among: ["api", "db"], stopping: true)

		#expect(blocked["db"] == ["api"])
		#expect(blocked["api"] == nil)
	}

	@Test("ignores an edge that leaves the set being acted on")
	func ignoresEdgesOutsideTheSet() {
		let subject = graph(["api": ["db"], "db": []])

		let blocked = subject.blockers(among: ["api"], stopping: false)

		#expect(blocked.isEmpty)
	}

	@Test("reaches what a dependency itself depends on")
	func closesOverTheWholeChain() {
		let subject = graph(["api": ["db"], "db": ["cache"], "cache": []])

		#expect(subject.closure(of: ["api"]) == ["api", "db", "cache"])
	}

	@Test("closes over a cycle without running away")
	func closesOverACycle() {
		let subject = graph(["api": ["db"], "db": ["api"]])

		#expect(subject.closure(of: ["api"]) == ["api", "db"])
	}
}
