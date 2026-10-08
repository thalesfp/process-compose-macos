import Testing

@testable import ProcessComposeCore

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

	@Test("drops the failure once the stream delivers again")
	func clearsTheFailureOnceLinesArrive() async {
		let client = StubClient()
		client.logStreamFailure = ProcessComposeError.unreachable(port: 28080)
		let viewModel = LogViewModel(client: client)
		viewModel.select("chatbot")
		await viewModel.stream()
		client.logStreamFailure = nil

		let session = Task { await viewModel.stream() }
		client.emitLog(.init(message: "listening", processName: "chatbot"))
		client.finishLogStream()
		await session.value

		#expect(viewModel.lastError == nil)
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

	@Test("shows only the lines holding the filter, whatever their case")
	func filtersLinesIgnoringCase() async {
		let client = StubClient()
		let viewModel = LogViewModel(client: client)
		viewModel.select("chatbot")

		let session = Task { await viewModel.stream() }
		client.emitLog(.init(message: "ERROR could not bind", processName: "chatbot"))
		client.emitLog(.init(message: "listening on 3001", processName: "chatbot"))
		client.emitLog(.init(message: "error retrying", processName: "chatbot"))
		client.finishLogStream()
		await session.value
		viewModel.filter = "error"

		#expect(viewModel.visibleLines.map(\.text) == ["ERROR could not bind", "error retrying"])
		#expect(viewModel.lines.count == 3)
	}

	@Test("shows every line again once the filter is emptied")
	func showsEverythingWithoutAFilter() async {
		let client = StubClient()
		let viewModel = LogViewModel(client: client)
		viewModel.select("chatbot")

		let session = Task { await viewModel.stream() }
		client.emitLog(.init(message: "listening on 3001", processName: "chatbot"))
		client.finishLogStream()
		await session.value
		viewModel.filter = ""

		#expect(viewModel.visibleLines.map(\.text) == ["listening on 3001"])
	}

	@Test("says how much of the buffer a filter is hiding")
	func describesTheFilteredCount() {
		#expect(LogFilter.countLabel(visible: 12, total: 400, filter: "error") == "12 of 400 lines")
		#expect(LogFilter.countLabel(visible: 400, total: 400, filter: "") == "400 lines")
	}

	@Test("drops the filter when another process is selected")
	func clearsFilterOnSelectionChange() async {
		let client = StubClient()
		let viewModel = LogViewModel(client: client)
		viewModel.select("chatbot")
		viewModel.filter = "error"

		viewModel.select("api")

		#expect(viewModel.filter == "")
	}
}

@MainActor
struct LogBufferBoundsTests {
	@Test("keeps a single enormous line from filling the buffer")
	func capsOneLine() {
		var buffer = LogBuffer(maxLines: 10)

		buffer.append(String(repeating: "x", count: 200_000))

		#expect(buffer.lines.first!.text.utf8.count <= LogBuffer.longestLine)
	}

	@Test("measures a line in bytes, so combining marks cannot slip past the limit")
	func capsByBytesNotCharacters() {
		var buffer = LogBuffer(maxLines: 10)

		// One character carrying many combining marks: a few characters, a great many bytes.
		let heavy = String(repeating: "e" + String(repeating: "\u{0301}", count: 20_000), count: 4)

		buffer.append(heavy)

		#expect(heavy.count < LogBuffer.longestLine)
		#expect(buffer.lines.first!.text.utf8.count <= LogBuffer.longestLine)
	}
}
