import Testing

@testable import ProcessComposeCore

private func wording(
	projects: [String: String] = [:],
	isConnected: Bool = true,
	running: Int = 0
) -> ConfirmationWording {
	ConfirmationWording(projectsByProcess: projects, isConnected: isConnected, runningCount: running)
}

struct ConfirmationWordingTests {
	@Test("names every project a stack stop reaches")
	func countsTheProjectsAStackStopReaches() {
		let subject = wording(projects: ["api": "acme", "chatbot": "ai"])

		#expect(subject.question(for: .stopStack(promised: ["api", "chatbot"]))
			== "Stop 2 running processes across 2 projects?")
	}

	@Test("leaves the project out when a stack stop stays inside one")
	func staysSilentAboutASingleProject() {
		let subject = wording(projects: ["api": "acme", "worker": "acme"])

		#expect(subject.question(for: .stopStack(promised: ["api", "worker"])) == "Stop 2 running processes?")
	}

	@Test("still counts a process whose project is not known yet")
	func countsAProcessWithNoProject() {
		let subject = wording(projects: ["api": "acme"])

		#expect(subject.question(for: .stopStack(promised: ["api", "stray"]))
			== "Stop 2 running processes across 2 projects?")
	}

	@Test("says what it cannot count when the app has no list of it")
	func admitsToNotKnowingWhatIsRunning() {
		let subject = wording(isConnected: false, running: 0)

		#expect(subject.question(for: .stopServer(identity: 0))
			== "Stop the server and every process it is running?")
	}

	@Test("asks only about the server when it is running nothing")
	func asksAboutAnIdleServer() {
		#expect(wording(running: 0).question(for: .stopServer(identity: 0)) == "Stop the server?")
	}

	@Test("agrees with the number of dependencies it names")
	func agreesWithTheNumberOfMissingDependencies() {
		let subject = wording(projects: ["db": "acme", "cache": "acme"])

		#expect(subject.question(for: .startProject("acme", missing: ["db"]))
			== "acme depends on db in acme, which is not running. Start acme anyway?")
		#expect(subject.question(for: .startProject("acme", missing: ["db", "cache"]))
			== "acme depends on db in acme, cache in acme, which are not running. Start acme anyway?")
	}

	@Test("names on the answer button what the question was about")
	func namesTheSubjectOnTheButton() {
		#expect(ConfirmationWording.answer(for: .stopStack(promised: [])) == "Stop the stack")
		#expect(ConfirmationWording.answer(for: .stopProject("acme", promised: [])) == "Stop acme")
		#expect(ConfirmationWording.answer(for: .stopServer(identity: 0)) == "Stop the server")
		#expect(ConfirmationWording.answer(for: .startProject("acme", missing: [])) == "Start acme")
	}

	@Test("marks everything but a start as destructive")
	func marksTakingSomethingAwayAsDestructive() {
		#expect(ConfirmTarget.stopStack(promised: []).isDestructive)
		#expect(ConfirmTarget.stopProject("acme", promised: []).isDestructive)
		#expect(ConfirmTarget.stopServer(identity: 0).isDestructive)
		#expect(!ConfirmTarget.startProject("acme", missing: []).isDestructive)
	}
}
