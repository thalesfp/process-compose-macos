import Foundation
import Testing

@testable import ProcessComposeCore

/// Answers for the names it was given, and can be told to refuse a name for a set number
/// of attempts, so the retry can be watched from outside.
private final class ConfigurationStub: ProcessComposeClient, @unchecked Sendable {
	private let lock = NSLock()
	private var refusals: [String: Int]
	private(set) var attempts: [String] = []
	let known: Set<String>

	init(known: Set<String>, refusing refusals: [String: Int] = [:]) {
		self.known = known
		self.refusals = refusals
	}

	func configuration(for name: String) async throws -> ProcessConfiguration {
		try lock.withLock {
			attempts.append(name)

			if let left = refusals[name], left > 0 {
				refusals[name] = left - 1
				throw ProcessComposeError.server(message: "no")
			}

			guard known.contains(name) else { throw ProcessComposeError.server(message: "unknown") }

			return ProcessConfiguration(workingDir: "/tmp/\(name)")
		}
	}

	func processes() async throws -> [ProcessState] { [] }
	func projectState() async throws -> ProjectState { throw ProcessComposeError.streamClosed }
	func start(_ name: String) async throws {}
	func stop(_ name: String) async throws {}
	func restart(_ name: String) async throws {}
	func stateEvents() -> AsyncThrowingStream<ProcessStateEvent, any Error> { .init { $0.finish() } }
	func logMessages(for name: String, backfill: Int) -> AsyncThrowingStream<LogMessage, any Error> {
		.init { $0.finish() }
	}
	func truncateLogs(for name: String) async throws {}
}

struct ConfigurationReaderTests {
	@Test("reads a configuration for every process it is asked about")
	func readsEveryConfiguration() async {
		let client = ConfigurationStub(known: ["api", "db"])

		let loaded = await ConfigurationReader.configurations(for: ["api", "db"], from: client)

		#expect(loaded.keys.sorted() == ["api", "db"])
		#expect(loaded["api"]?.workingDir == "/tmp/api")
	}

	@Test("asks again for a process the server refused once")
	func retriesASingleBlip() async {
		let client = ConfigurationStub(known: ["api", "db"], refusing: ["db": 1])

		let loaded = await ConfigurationReader.configurations(for: ["api", "db"], from: client)

		#expect(loaded.keys.sorted() == ["api", "db"])
		#expect(client.attempts.filter { $0 == "db" }.count == 2)
	}

	@Test("asks again only for what it is still missing")
	func leavesTheReadOnesAlone() async {
		let client = ConfigurationStub(known: ["api", "db"], refusing: ["db": 1])

		_ = await ConfigurationReader.configurations(for: ["api", "db"], from: client)

		#expect(client.attempts.filter { $0 == "api" }.count == 1)
	}

	@Test("leaves out a process the server keeps refusing, rather than failing the read")
	func leavesOutWhatItCannotRead() async {
		let client = ConfigurationStub(known: ["api", "db"], refusing: ["db": 5])

		let loaded = await ConfigurationReader.configurations(for: ["api", "db"], from: client)

		#expect(loaded.keys.sorted() == ["api"])
		#expect(client.attempts.filter { $0 == "db" }.count == 2)
	}
}
