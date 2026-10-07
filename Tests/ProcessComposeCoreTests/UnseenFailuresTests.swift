import Testing

@testable import ProcessComposeCore

private func running(_ name: String) -> ProcessState {
	ProcessState(name: name, status: .running, isRunning: true)
}

private func failed(_ name: String, exitCode: Int = 1) -> ProcessState {
	ProcessState(name: name, status: .completed, exitCode: exitCode)
}

struct UnseenFailuresTests {
	@Test("announces nothing for processes already failed when the app connects")
	func ignoresFailuresFoundOnConnect() {
		var failures = UnseenFailures()

		let news = failures.observe([failed("migrate"), running("api")], isActive: false)

		#expect(news.isEmpty)
		#expect(failures.names.isEmpty)
	}

	@Test("announces a process that fails while the app is in the background")
	func announcesABackgroundFailure() {
		var failures = UnseenFailures()
		_ = failures.observe([running("api")], isActive: false)

		let news = failures.observe([failed("api")], isActive: false)

		#expect(news.map(\.name) == ["api"])
		#expect(failures.names == ["api"])
	}

	@Test("counts nothing that fails while the user is looking")
	func ignoresAFailureSeenAsItHappens() {
		var failures = UnseenFailures()
		_ = failures.observe([running("api")], isActive: true)

		let news = failures.observe([failed("api")], isActive: true)

		#expect(news.isEmpty)
		#expect(failures.names.isEmpty)
	}

	@Test("announces a crash loop once until the user comes back")
	func announcesACrashLoopOnce() {
		var failures = UnseenFailures()
		_ = failures.observe([running("flaky")], isActive: false)
		_ = failures.observe([failed("flaky")], isActive: false)
		_ = failures.observe([running("flaky")], isActive: false)

		let news = failures.observe([failed("flaky")], isActive: false)

		#expect(news.isEmpty)
		#expect(failures.names == ["flaky"])
	}

	@Test("clears what it counts once the user comes back")
	func clearsOnReturn() {
		var failures = UnseenFailures()
		_ = failures.observe([running("api")], isActive: false)
		_ = failures.observe([failed("api")], isActive: false)

		failures.acknowledge()

		#expect(failures.names.isEmpty)
	}

	@Test("announces the same process again after the user has seen it")
	func announcesAgainAfterReturn() {
		var failures = UnseenFailures()
		_ = failures.observe([running("api")], isActive: false)
		_ = failures.observe([failed("api")], isActive: false)
		failures.acknowledge()
		_ = failures.observe([running("api")], isActive: false)

		let news = failures.observe([failed("api")], isActive: false)

		#expect(news.map(\.name) == ["api"])
	}

	@Test("announces failures that arrive together as one batch")
	func batchesSimultaneousFailures() {
		var failures = UnseenFailures()
		_ = failures.observe([running("worker"), running("api")], isActive: false)

		let news = failures.observe([failed("worker"), failed("api")], isActive: false)

		#expect(news.map(\.name) == ["api", "worker"])
	}

	@Test("takes a stopped process for a stop, not a failure")
	func ignoresASignalledStop() {
		var failures = UnseenFailures()
		_ = failures.observe([running("worker")], isActive: false)

		let news = failures.observe([failed("worker", exitCode: -1)], isActive: false)

		#expect(news.isEmpty)
	}

	@Test("starts over once the server goes away")
	func startsOverAfterADisconnect() {
		var failures = UnseenFailures()
		_ = failures.observe([running("api")], isActive: false)
		_ = failures.observe([], isActive: false)

		let news = failures.observe([failed("api")], isActive: false)

		#expect(news.isEmpty)
	}

	@Test("names one failure and how it ended")
	func wordsOneFailure() {
		let failure = [failed("migrate", exitCode: 2)]

		#expect(FailureAnnouncement.title(for: failure) == "migrate failed")
		#expect(FailureAnnouncement.body(for: failure) == "It exited with code 2.")
	}

	@Test("counts several failures and names them")
	func wordsSeveralFailures() {
		let failures = [failed("api"), failed("worker")]

		#expect(FailureAnnouncement.title(for: failures) == "2 processes failed")
		#expect(FailureAnnouncement.body(for: failures) == "api, worker")
	}
}
