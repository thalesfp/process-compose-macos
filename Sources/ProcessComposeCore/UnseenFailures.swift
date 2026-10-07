/// Processes that failed while the app was in the background: what the Dock badge counts
/// and what a notification announces. Each one is announced once until the user comes back.
public struct UnseenFailures: Sendable, Equatable {
	public private(set) var names: Set<String> = []

	/// Nil until the first states of a connection, which only say what had already failed.
	private var failedBefore: Set<String>?

	public init() {}

	/// Takes the latest states and returns the failures that are news, in name order.
	public mutating func observe(_ states: [ProcessState], isActive: Bool) -> [ProcessState] {
		guard !states.isEmpty else {
			failedBefore = nil
			return []
		}

		let failed = states.filter { $0.indicator == .failed }
		let before = failedBefore

		failedBefore = Set(failed.map(\.name))

		guard let before, !isActive else { return [] }

		let news = failed.filter { !before.contains($0.name) && !names.contains($0.name) }

		names.formUnion(news.map(\.name))

		return news.sorted { $0.name < $1.name }
	}

	/// The user came back to the app and has seen what failed.
	public mutating func acknowledge() {
		names = []
	}
}

/// The words a failure notification uses.
public enum FailureAnnouncement {
	public static func title(for failed: [ProcessState]) -> String {
		guard failed.count == 1, let only = failed.first else { return "\(failed.count) processes failed" }

		return "\(only.name) failed"
	}

	public static func body(for failed: [ProcessState]) -> String {
		guard failed.count == 1, let only = failed.first else {
			return failed.map(\.name).joined(separator: ", ")
		}

		return only.status == .error ? "process-compose could not run it." : "It exited with code \(only.exitCode)."
	}
}
