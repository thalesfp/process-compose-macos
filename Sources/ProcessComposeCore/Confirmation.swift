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

/// A question and the moment it was asked. An answer captured before the work was
/// abandoned cannot be acted on afterwards.
public struct Confirmation: Sendable, Equatable {
	public let target: ConfirmTarget
	let epoch: Int
}

/// The words a question and its answer button use. Three of the four questions count from
/// what the target promised, so those numbers hold still while the dialog is open. The
/// server has no promise to count, so its question reads the stack, and the caller passes
/// what it sees at the moment the words are asked for.
public enum ConfirmationWording {
	public static func question(
		for target: ConfirmTarget,
		projectsByProcess: [String: String],
		isConnected: Bool,
		runningCount: Int
	) -> String {
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
			guard isConnected else {
				return "Stop the server and every process it is running?"
			}

			return runningCount == 0 ? "Stop the server?" : "Stop the server and \(Self.runningLabel(runningCount))?"
		case .startProject(let name, let missing):
			let named = missing.map { "\($0) in \(projectsByProcess[$0] ?? ProcessGrouping.ungrouped)" }
			let verb = named.count == 1 ? "is" : "are"

			return "\(name) depends on \(named.joined(separator: ", ")), which \(verb) not running. Start \(name) anyway?"
		}
	}

	/// What the button that answers the question says.
	public static func answer(for target: ConfirmTarget) -> String {
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
}
