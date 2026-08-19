import Testing

@testable import ConductorCore

struct LogRenderingTests {
	@Test("draws every buffered line into an empty view")
	func appendsIntoEmptyView() {
		let lines = [line(0, "boot"), line(1, "ready")]

		let plan = LogRendering.plan(rendered: [], lines: lines)

		#expect(plan.dropLeading == 0)
		#expect(plan.append.map(\.text) == ["boot", "ready"])
	}

	@Test("appends only the lines that arrived since the last draw")
	func appendsOnlyNewLines() {
		let lines = [line(0, "boot"), line(1, "ready"), line(2, "request")]

		let plan = LogRendering.plan(rendered: [0, 1], lines: lines)

		#expect(plan.dropLeading == 0)
		#expect(plan.append.map(\.text) == ["request"])
	}

	@Test("drops the lines the buffer trimmed off the front")
	func dropsTrimmedLines() {
		let lines = [line(2, "request"), line(3, "response")]

		let plan = LogRendering.plan(rendered: [0, 1, 2], lines: lines)

		#expect(plan.dropLeading == 2)
		#expect(plan.append.map(\.text) == ["response"])
	}

	@Test("redraws everything when the buffer is replaced by another process")
	func redrawsOnProcessSwitch() {
		let lines = [line(9, "other process")]

		let plan = LogRendering.plan(rendered: [0, 1, 2], lines: lines)

		#expect(plan.dropLeading == 3)
		#expect(plan.append.map(\.text) == ["other process"])
	}

	@Test("clears the view when the buffer is emptied")
	func clearsOnEmptyBuffer() {
		let plan = LogRendering.plan(rendered: [0, 1], lines: [])

		#expect(plan.dropLeading == 2)
		#expect(plan.append.isEmpty)
	}

	@Test("reports nothing to do when the view is already current")
	func reportsNothingToDo() {
		let lines = [line(0, "boot")]

		let plan = LogRendering.plan(rendered: [0], lines: lines)

		#expect(plan.isEmpty)
	}

	@Test("keeps the font size inside the readable range")
	func clampsFontSize() {
		#expect(LogFont.stepped(14, by: 1) == 15)
		#expect(LogFont.stepped(LogFont.range.upperBound, by: 1) == LogFont.range.upperBound)
		#expect(LogFont.stepped(LogFont.range.lowerBound, by: -1) == LogFont.range.lowerBound)
	}

	private func line(_ id: Int, _ text: String) -> LogLine {
		LogLine(id: id, processName: "api", spans: [AnsiSpan(text: text)])
	}
}
