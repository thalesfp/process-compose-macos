/// Why the app is being asked to quit.
public enum QuitReason: Sendable, Equatable {
	/// Cmd+Q, closing the window, Quit All, or a request that does not say.
	case user
	/// Log out, restart or shut down, where waiting on a question would hold the whole Mac up.
	case system
}

/// What AppKit is told about a request to terminate, and what the app does next.
public enum QuitDecision: Sendable, Equatable {
	case terminateNow
	/// Decline this request and ask about the server with this identity.
	case ask(identity: Int)
	/// A quit is already being asked about or carried out; show the window instead.
	case bringForward
	/// Answer later, once the server has stopped or the deadline has passed.
	case stopForSystem
}

/// What follows the user's answer, or the end of a stop they agreed to.
public enum QuitStep: Sendable, Equatable {
	case stop(identity: Int)
	case terminate
	case showFailure
	/// The server the question was about has been replaced, so the question starts over.
	case askAgain
	case nothing
}

public enum QuitPhase: Sendable, Equatable {
	case idle
	case asking(identity: Int)
	case stopping(forSystem: Bool)
	/// The stack survived the stop, and the user decides what happens next.
	case failed
	case approved(leavingRunning: Bool)
}

/// Every request to quit goes through one of these, so two requests can never ask twice,
/// stop the stack twice, or answer the system twice.
public struct QuitFlow: Sendable, Equatable {
	public private(set) var phase: QuitPhase = .idle

	public init() {}

	public var isQuitting: Bool {
		phase != .idle
	}

	public var isStopping: Bool {
		if case .stopping = phase { return true }
		return false
	}

	/// The stack is left as it is at exit: the user chose to, or the system could not wait.
	public var leavesStackRunning: Bool {
		phase == .approved(leavingRunning: true)
	}

	public mutating func request(_ reason: QuitReason, holdsServer: Bool, identity: Int) -> QuitDecision {
		if case .approved = phase { return .terminateNow }

		guard holdsServer else {
			phase = .approved(leavingRunning: false)
			return .terminateNow
		}

		if reason == .system {
			phase = .stopping(forSystem: true)
			return .stopForSystem
		}

		guard phase == .idle else { return .bringForward }

		phase = .asking(identity: identity)
		return .ask(identity: identity)
	}

	/// The user agreed to stop the server. Agreement was given for the server they were
	/// shown, and a restart at the same address is another one.
	public mutating func confirm(currentIdentity: Int) -> QuitStep {
		guard case .asking(let asked) = phase else { return .nothing }

		guard asked == currentIdentity else {
			phase = .idle
			return .askAgain
		}

		phase = .stopping(forSystem: false)
		return .stop(identity: asked)
	}

	public mutating func cancel() {
		guard case .asking = phase else { return }

		phase = .idle
	}

	/// A stop the user agreed to has ended. A system quit that took over in the meantime
	/// answers for itself.
	public mutating func userStopFinished(_ outcome: StopOutcome) -> QuitStep {
		guard phase == .stopping(forSystem: false) else { return .nothing }

		switch outcome {
		case .stopped, .nothingToStop:
			phase = .approved(leavingRunning: false)
			return .terminate
		case .stillRunning:
			phase = .failed
			return .showFailure
		case .identityChanged:
			phase = .idle
			return .askAgain
		}
	}

	public mutating func tryAgain(currentIdentity: Int) -> QuitStep {
		guard phase == .failed else { return .nothing }

		phase = .stopping(forSystem: false)
		return .stop(identity: currentIdentity)
	}

	public mutating func quitAnyway() -> QuitStep {
		guard phase == .failed else { return .nothing }

		phase = .approved(leavingRunning: true)
		return .terminate
	}

	public mutating func keepOpen() {
		guard phase == .failed else { return }

		phase = .idle
	}

	/// The system's stop ended or its deadline passed. Only the first of the two answers,
	/// since AppKit takes exactly one reply to a deferred termination.
	public mutating func systemStopFinished(_ outcome: StopOutcome?) -> Bool {
		guard phase == .stopping(forSystem: true) else { return false }

		phase = .approved(leavingRunning: outcome != .stopped && outcome != .nothingToStop)
		return true
	}
}
