import Testing

@testable import ProcessComposeCore

private func question(
	_ target: ConfirmTarget,
	projects: [String: String] = [:],
	isConnected: Bool = true,
	running: Int = 0
) -> String {
	ConfirmationWording.question(
		for: target,
		projectsByProcess: projects,
		isConnected: isConnected,
		runningCount: running
	)
}

struct ConfirmationWordingTests {
	@Test("names every project a stack stop reaches")
	func countsTheProjectsAStackStopReaches() {
		let words = question(.stopStack(promised: ["api", "chatbot"]), projects: ["api": "acme", "chatbot": "ai"])

		#expect(words == "Stop 2 running processes across 2 projects?")
	}

	@Test("leaves the project out when a stack stop stays inside one")
	func staysSilentAboutASingleProject() {
		let words = question(.stopStack(promised: ["api", "worker"]), projects: ["api": "acme", "worker": "acme"])

		#expect(words == "Stop 2 running processes?")
	}

	@Test("still counts a process whose project is not known yet")
	func countsAProcessWithNoProject() {
		let words = question(.stopStack(promised: ["api", "stray"]), projects: ["api": "acme"])

		#expect(words == "Stop 2 running processes across 2 projects?")
	}

	@Test("says what it cannot count when the app has no list of it")
	func admitsToNotKnowingWhatIsRunning() {
		let words = question(.stopServer(identity: 0), isConnected: false)

		#expect(words == "Stop the server and every process it is running?")
	}

	@Test("asks only about the server when it is running nothing")
	func asksAboutAnIdleServer() {
		#expect(question(.stopServer(identity: 0), running: 0) == "Stop the server?")
	}

	@Test("agrees with the number of dependencies it names")
	func agreesWithTheNumberOfMissingDependencies() {
		let projects = ["db": "acme", "cache": "acme"]

		#expect(question(.startProject("acme", missing: ["db"]), projects: projects)
			== "acme depends on db in acme, which is not running. Start acme anyway?")
		#expect(question(.startProject("acme", missing: ["db", "cache"]), projects: projects)
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
