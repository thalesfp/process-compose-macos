import Foundation
import Testing

@testable import ProcessComposeCore

struct AnsiParserTests {
	@Test("plain text comes back as one unstyled span")
	func plainText() {
		let spans = AnsiParser.spans(in: "chatbot listening on 3001")

		#expect(spans == [AnsiSpan(text: "chatbot listening on 3001")])
	}

	@Test("keeps the colored run and the text after the reset")
	func coloredRun() {
		let spans = AnsiParser.spans(in: "\u{1b}[36mready\u{1b}[0m in 412ms")

		#expect(spans == [
			AnsiSpan(text: "ready", color: .cyan),
			AnsiSpan(text: " in 412ms"),
		])
	}

	@Test("reads bold and a bright color together")
	func boldBrightColor() {
		let spans = AnsiParser.spans(in: "\u{1b}[1;91mERROR\u{1b}[0m")

		#expect(spans == [AnsiSpan(text: "ERROR", color: .red, isBold: true)])
	}

	@Test("drops cursor and erase sequences without eating the text")
	func dropsNonColorEscapes() {
		let spans = AnsiParser.spans(in: "\u{1b}[2K\u{1b}[1Gbuilding")

		#expect(spans.map(\.text).joined() == "building")
	}

	@Test("a bare reset restores the default style")
	func bareReset() {
		let spans = AnsiParser.spans(in: "\u{1b}[31mred\u{1b}[mplain")

		#expect(spans == [
			AnsiSpan(text: "red", color: .red),
			AnsiSpan(text: "plain"),
		])
	}

	@Test("an unterminated escape does not lose the rest of the line")
	func unterminatedEscape() {
		let spans = AnsiParser.spans(in: "before\u{1b}[38;5")

		#expect(spans.map(\.text).joined() == "before")
	}
}

struct LogMessageTests {
	@Test("decodes the server's log frame")
	func decodesLogFrame() throws {
		let json = #"{"message":"listening on 3001","process_name":"chatbot"}"#.data(using: .utf8)!

		let message = try JSONDecoder().decode(LogMessage.self, from: json)

		#expect(message.processName == "chatbot")
		#expect(message.message == "listening on 3001")
	}
}
