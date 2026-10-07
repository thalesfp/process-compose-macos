import AppKit
import Observation
import ProcessComposeCore

/// The one place a quit is decided and carried out, whether it came from closing the
/// window, Cmd+Q, the Dock, or the Mac logging out.
@MainActor
@Observable
final class QuitCoordinator {
	// macOS waits about two minutes for a deferred reply before it gives up on a log out.
	private static let systemDeadline: Duration = .seconds(90)

	private(set) var flow = QuitFlow()

	/// What was running when the stop began. The connection goes with the server, so this
	/// is what was last known rather than what is running now.
	private(set) var stoppingProcesses: [String] = []

	@ObservationIgnored private let model: StackViewModel
	@ObservationIgnored private let server: ServerSupervisor
	@ObservationIgnored private weak var window: NSWindow?
	@ObservationIgnored private var presented: NSAlert?

	init(model: StackViewModel, server: ServerSupervisor) {
		self.model = model
		self.server = server
	}

	var isQuitting: Bool { flow.isQuitting }
	var isStopping: Bool { flow.isStopping }
	var leavesStackRunning: Bool { flow.leavesStackRunning }

	/// The stack window, where every question about quitting is asked.
	func attach(_ window: NSWindow) {
		self.window = window
	}

	/// The stack window is the app, so closing it is quitting it.
	func closeRequested() {
		NSApp.terminate(nil)
	}

	/// AppKit refuses to terminate while a sheet is up, before it asks the delegate, so a
	/// question still on screen would hold up a log out. The system's quit clears it first.
	func makeRoom(for reason: QuitReason) {
		guard reason == .system else { return }

		dismissPresented()
	}

	/// AppKit wants its answer at once, so anything that waits on the user or the stack
	/// happens after this returns.
	func shouldTerminate(_ reason: QuitReason) -> NSApplication.TerminateReply {
		let decision = change { $0.request(reason, holdsServer: server.holdsServer, identity: server.identity) }

		switch decision {
		case .terminateNow:
			return .terminateNow
		case .ask:
			Task { self.ask() }
			return .terminateCancel
		case .bringForward:
			bringForward()
			return .terminateCancel
		case .stopForSystem:
			stopForSystem()
			return .terminateLater
		}
	}

	private func ask() {
		let alert = NSAlert()
		alert.messageText = "Stop the stack and quit?"
		alert.informativeText = "The app started this server. Quitting stops it and every process it is running."
		alert.addButton(withTitle: "Stop and Quit").hasDestructiveAction = true
		alert.addButton(withTitle: "Cancel")

		present(alert) { [weak self] response in
			guard let self else { return }

			guard response == .alertFirstButtonReturn else {
				self.change { $0.cancel() }
				return
			}

			self.carryOut(self.change { $0.confirm(currentIdentity: self.server.identity) })
		}
	}

	private func showFailure() {
		let alert = NSAlert()
		alert.alertStyle = .warning
		alert.messageText = "The stack is still running"
		alert.informativeText = "It did not stop when asked, or when forced. Some processes may already have stopped."
		alert.addButton(withTitle: "Try Again")
		alert.addButton(withTitle: "Quit Anyway")
		alert.addButton(withTitle: "Keep App Open").keyEquivalent = "\u{1b}"

		present(alert) { [weak self] response in
			guard let self else { return }

			switch response {
			case .alertFirstButtonReturn:
				self.carryOut(self.change { $0.tryAgain(currentIdentity: self.server.identity) })
			case .alertSecondButtonReturn:
				self.carryOut(self.change { $0.quitAnyway() })
			default:
				self.change { $0.keepOpen() }
			}
		}
	}

	private func carryOut(_ step: QuitStep) {
		switch step {
		case .stop(let identity):
			stopForUser(identity)
		case .terminate:
			NSApp.terminate(nil)
		case .showFailure:
			showFailure()
		case .askAgain:
			// A new request asks about the server there is now, or quits if there is none.
			NSApp.terminate(nil)
		case .nothing:
			break
		}
	}

	private func stopForUser(_ identity: Int) {
		beginStopping()

		Task {
			let outcome = await server.stop(expecting: identity)
			carryOut(change { $0.userStopFinished(outcome) })
		}
	}

	private func stopForSystem() {
		dismissPresented()
		beginStopping()

		Task {
			let outcome = await server.stop()
			finishSystemQuit(outcome)
		}

		Task {
			try? await Task.sleep(for: Self.systemDeadline)
			finishSystemQuit(nil)
		}
	}

	private func finishSystemQuit(_ outcome: StopOutcome?) {
		guard change({ $0.systemStopFinished(outcome) }) else { return }

		NSApp.reply(toApplicationShouldTerminate: true)
	}

	private func beginStopping() {
		stoppingProcesses = model.runningProcesses.map(\.name).sorted()
		model.abandonActions()
	}

	/// Every change to the flow goes through here, so the model's lock follows it.
	@discardableResult
	private func change<Result>(_ body: (inout QuitFlow) -> Result) -> Result {
		let result = body(&flow)
		model.isQuitting = flow.isQuitting
		return result
	}

	private func present(_ alert: NSAlert, then handle: @escaping (NSApplication.ModalResponse) -> Void) {
		presented = alert

		let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
			if self?.presented === alert { self?.presented = nil }
			handle(response)
		}

		guard let window else {
			finish(alert.runModal())
			return
		}

		bringForward()
		alert.beginSheetModal(for: window, completionHandler: finish)
	}

	/// A system quit takes over from whatever the user was being asked.
	private func dismissPresented() {
		guard let alert = presented, let window, alert.window.sheetParent === window else { return }

		window.endSheet(alert.window)
	}

	private func bringForward() {
		NSApp.activate()
		window?.deminiaturize(nil)
		window?.makeKeyAndOrderFront(nil)
	}
}

extension QuitReason {
	static var ofCurrentEvent: QuitReason {
		QuitReason(event: NSAppleEventManager.shared().currentAppleEvent)
	}

	/// The quit Apple event names its reason, and only log out, restart and shut down are
	/// the system's. A request that names none came from the user.
	init(event: NSAppleEventDescriptor?) {
		let why = event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
		let code = why.map { $0.enumCodeValue != 0 ? $0.enumCodeValue : $0.typeCodeValue }

		switch code {
		case OSType(kAEShutDown), OSType(kAERestart), OSType(kAEReallyLogOut): self = .system
		default: self = .user
		}
	}
}
