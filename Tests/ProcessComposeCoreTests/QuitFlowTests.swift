import Testing

@testable import ProcessComposeCore

private func asking(identity: Int = 7) -> QuitFlow {
	var flow = QuitFlow()
	_ = flow.request(.user, holdsServer: true, identity: identity)
	return flow
}

private func stopping(identity: Int = 7) -> QuitFlow {
	var flow = asking(identity: identity)
	_ = flow.confirm(currentIdentity: identity)
	return flow
}

private func failed() -> QuitFlow {
	var flow = stopping()
	_ = flow.userStopFinished(.stillRunning)
	return flow
}

struct QuitFlowTests {
	@Test("quits at once when the app holds no server")
	func quitsWithoutAServer() {
		var flow = QuitFlow()

		let decision = flow.request(.user, holdsServer: false, identity: 7)

		#expect(decision == .terminateNow)
		#expect(flow.leavesStackRunning == false)
	}

	@Test("asks about the server it holds before quitting")
	func asksAboutAHeldServer() {
		var flow = QuitFlow()

		let decision = flow.request(.user, holdsServer: true, identity: 7)

		#expect(decision == .ask(identity: 7))
	}

	@Test("shows the window instead of asking twice")
	func bringsTheWindowForwardOnASecondQuit() {
		var flow = asking()

		let decision = flow.request(.user, holdsServer: true, identity: 7)

		#expect(decision == .bringForward)
	}

	@Test("stays open when the user cancels")
	func staysOpenOnCancel() {
		var flow = asking()

		flow.cancel()

		#expect(flow.phase == .idle)
	}

	@Test("stops the server the user agreed to stop")
	func stopsOnConfirmation() {
		var flow = asking(identity: 7)

		let step = flow.confirm(currentIdentity: 7)

		#expect(step == .stop(identity: 7))
		#expect(flow.isStopping)
	}

	@Test("asks again when the server was replaced while the question was open")
	func asksAgainForAReplacedServer() {
		var flow = asking(identity: 7)

		let step = flow.confirm(currentIdentity: 8)

		#expect(step == .askAgain)
		#expect(flow.phase == .idle)
	}

	@Test("quits once the stack has stopped")
	func quitsAfterAStop() {
		var flow = stopping()

		let step = flow.userStopFinished(.stopped)

		#expect(step == .terminate)
		#expect(flow.request(.user, holdsServer: true, identity: 7) == .terminateNow)
		#expect(flow.leavesStackRunning == false)
	}

	@Test("lets the user decide when the stack survives the stop")
	func showsTheFailure() {
		var flow = stopping()

		let step = flow.userStopFinished(.stillRunning)

		#expect(step == .showFailure)
		#expect(flow.phase == .failed)
	}

	@Test("asks again when the server changed before the stop reached it")
	func asksAgainWhenTheStopFoundAnotherServer() {
		var flow = stopping()

		let step = flow.userStopFinished(.identityChanged)

		#expect(step == .askAgain)
	}

	@Test("tries the stop again when asked to")
	func triesAgain() {
		var flow = failed()

		let step = flow.tryAgain(currentIdentity: 9)

		#expect(step == .stop(identity: 9))
	}

	@Test("leaves the stack running when the user quits anyway")
	func quitsAnyway() {
		var flow = failed()

		let step = flow.quitAnyway()

		#expect(step == .terminate)
		#expect(flow.leavesStackRunning)
	}

	@Test("stays open with the stack as it is when the user keeps the app open")
	func keepsTheAppOpen() {
		var flow = failed()

		flow.keepOpen()

		#expect(flow.phase == .idle)
	}

	@Test("stops without asking when the Mac logs out or shuts down")
	func stopsForTheSystem() {
		var flow = QuitFlow()

		let decision = flow.request(.system, holdsServer: true, identity: 7)

		#expect(decision == .stopForSystem)
	}

	@Test("lets the system quit take over a question that is still open")
	func systemQuitTakesOverAQuestion() {
		var flow = asking()

		let decision = flow.request(.system, holdsServer: true, identity: 7)

		#expect(decision == .stopForSystem)
		#expect(flow.confirm(currentIdentity: 7) == .nothing)
	}

	@Test("lets the system quit take over a stop the user started")
	func systemQuitTakesOverAUserStop() {
		var flow = stopping()

		_ = flow.request(.system, holdsServer: true, identity: 7)

		#expect(flow.userStopFinished(.stopped) == .nothing)
	}

	@Test("answers the system exactly once")
	func answersTheSystemOnce() {
		var flow = QuitFlow()
		_ = flow.request(.system, holdsServer: true, identity: 7)

		let first = flow.systemStopFinished(nil)
		let second = flow.systemStopFinished(.stopped)

		#expect(first)
		#expect(second == false)
	}

	@Test("leaves the stack running when the system could not wait for it")
	func leavesTheStackWhenTheDeadlinePassed() {
		var flow = QuitFlow()
		_ = flow.request(.system, holdsServer: true, identity: 7)

		_ = flow.systemStopFinished(nil)

		#expect(flow.leavesStackRunning)
	}

	@Test("leaves nothing behind when the system's stop finished in time")
	func leavesNothingWhenTheSystemStopFinished() {
		var flow = QuitFlow()
		_ = flow.request(.system, holdsServer: true, identity: 7)

		_ = flow.systemStopFinished(.stopped)

		#expect(flow.leavesStackRunning == false)
	}
}
