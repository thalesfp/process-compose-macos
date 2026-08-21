import Foundation

/// One frame from the log socket.
public struct LogMessage: Decodable, Sendable, Hashable {
	public let message: String
	public let processName: String

	public init(message: String, processName: String) {
		self.message = message
		self.processName = processName
	}

	enum CodingKeys: String, CodingKey {
		case message
		case processName = "process_name"
	}
}

/// A buffered line, carrying an identity the log view can diff on.
public struct LogLine: Sendable, Hashable, Identifiable {
	public let id: Int
	public let spans: [AnsiSpan]

	public init(id: Int, spans: [AnsiSpan]) {
		self.id = id
		self.spans = spans
	}

	public var text: String {
		spans.map(\.text).joined()
	}
}

public struct AnsiSpan: Sendable, Hashable {
	public let text: String
	public let color: AnsiColor?
	public let isBold: Bool

	public init(text: String, color: AnsiColor? = nil, isBold: Bool = false) {
		self.text = text
		self.color = color
		self.isBold = isBold
	}
}

public enum AnsiColor: Sendable, Hashable {
	case black, red, green, yellow, blue, magenta, cyan, white

	init?(sgr code: Int) {
		switch code % 10 {
		case 0: self = .black
		case 1: self = .red
		case 2: self = .green
		case 3: self = .yellow
		case 4: self = .blue
		case 5: self = .magenta
		case 6: self = .cyan
		case 7: self = .white
		default: return nil
		}
	}
}

public enum AnsiParser {
	/// Splits a line into styled spans. Only SGR (`ESC[…m`) is interpreted; every
	/// other escape sequence is dropped, since a scrolling log pane cannot honour
	/// cursor movement or erase codes.
	public static func spans(in line: String) -> [AnsiSpan] {
		var spans: [AnsiSpan] = []
		var pending = ""
		var color: AnsiColor?
		var isBold = false

		func flush() {
			guard !pending.isEmpty else { return }
			spans.append(AnsiSpan(text: pending, color: color, isBold: isBold))
			pending = ""
		}

		var rest = Substring(line)
		while let escape = rest.firstIndex(of: "\u{1b}") {
			pending += rest[rest.startIndex ..< escape]
			rest = rest[rest.index(after: escape)...]

			guard rest.first == "[" else {
				// Not a CSI sequence: the escape is dropped and the text carries on.
				continue
			}

			let afterBracket = rest.index(after: rest.startIndex)
			guard let terminator = rest[afterBracket...].firstIndex(where: { $0.isANSITerminator }) else {
				rest = rest[rest.endIndex...]
				continue
			}

			let parameters = rest[afterBracket ..< terminator]
			let final = rest[terminator]
			rest = rest[rest.index(after: terminator)...]

			guard final == "m" else { continue }

			flush()
			let codes = parameters.split(separator: ";").compactMap { Int($0) }
			for code in codes.isEmpty ? [0] : codes {
				switch code {
				case 0: color = nil; isBold = false
				case 1: isBold = true
				case 22: isBold = false
				case 39: color = nil
				case 30 ... 37, 90 ... 97: color = AnsiColor(sgr: code)
				default: break
				}
			}
		}

		pending += rest
		flush()

		return spans.isEmpty ? [AnsiSpan(text: "")] : spans
	}
}

extension Character {
	fileprivate var isANSITerminator: Bool {
		guard let ascii = asciiValue else { return false }
		return (0x40 ... 0x7E).contains(ascii)
	}
}
