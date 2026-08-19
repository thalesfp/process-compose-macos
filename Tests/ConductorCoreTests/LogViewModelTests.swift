import Testing

@testable import ConductorCore

@MainActor
struct LogViewModelTests {
	@Test("shows the lines the server replays for the selected process")
	func showsReplayedLines() async {
		let client = StubClient()
		let viewModel = LogViewModel(client: client)
		viewModel.select("chatbot")

		let session = Task { await viewModel.stream() }
		client.emitLog(.init(message: "listening on 3001", processName: "chatbot"))
		client.finishLogStream()
		await session.value

		#expect(viewModel.lines.map(\.text) == ["listening on 3001"])
	}

	@Test("keeps only the newest lines once the buffer is full")
	func trimsToBufferLimit() async {
		let client = StubClient()
		let viewModel = LogViewModel(client: client, maxLines: 3)
		viewModel.select("chatbot")

		let session = Task { await viewModel.stream() }
		for index in 1 ... 5 {
			client.emitLog(.init(message: "line \(index)", processName: "chatbot"))
		}
		client.finishLogStream()
		await session.value

		#expect(viewModel.lines.map(\.text) == ["line 3", "line 4", "line 5"])
	}

	@Test("empties the pane when another process is selected")
	func clearsOnSelectionChange() async {
		let client = StubClient()
		let viewModel = LogViewModel(client: client)
		viewModel.select("chatbot")

		let session = Task { await viewModel.stream() }
		client.emitLog(.init(message: "old", processName: "chatbot"))
		client.finishLogStream()
		await session.value

		viewModel.select("api")

		#expect(viewModel.lines.isEmpty)
		#expect(viewModel.selected == "api")
	}

	@Test("clearing empties the pane and truncates on the server")
	func clearTruncatesServerSide() async {
		let client = StubClient()
		let viewModel = LogViewModel(client: client)
		viewModel.select("chatbot")

		let session = Task { await viewModel.stream() }
		client.emitLog(.init(message: "noise", processName: "chatbot"))
		client.finishLogStream()
		await session.value

		await viewModel.clear()

		#expect(viewModel.lines.isEmpty)
		#expect(client.truncated == ["chatbot"])
	}

	@Test("reports why the log stream failed")
	func reportsStreamFailure() async {
		let client = StubClient()
		client.logStreamFailure = ProcessComposeError.unreachable(port: 28080)
		let viewModel = LogViewModel(client: client)
		viewModel.select("chatbot")

		await viewModel.stream()

		#expect(viewModel.lastError == "No process-compose server on port 28080")
	}

	@Test("colors survive into the buffered line")
	func keepsAnsiColor() async {
		let client = StubClient()
		let viewModel = LogViewModel(client: client)
		viewModel.select("chatbot")

		let session = Task { await viewModel.stream() }
		client.emitLog(.init(message: "\u{1b}[32mok\u{1b}[0m", processName: "chatbot"))
		client.finishLogStream()
		await session.value

		#expect(viewModel.lines.first?.spans.first?.color == .green)
	}
}
