import Foundation

/// The window of lines a log pane keeps: parsed on the way in, oldest dropped once it is full.
public struct LogBuffer: Sendable {
	public private(set) var lines: [LogLine] = []

	/// Lowering this drops the oldest lines at once. Settings lets the user type any
	/// integer, so the value is clamped on the way in.
	public var maxLines: Int {
		get { limit }
		set {
			limit = max(1, newValue)
			trim()
		}
	}

	/// A line the pane can show is short; a stack that prints a megabyte on one line would
	/// otherwise be held whole, and the line count alone does not bound that.
	static let longestLine = 4096

	private var limit: Int
	private var nextID = 0

	public init(maxLines: Int) {
		self.limit = max(1, maxLines)
	}

	public mutating func append(_ text: String) {
		let kept = String(decoding: LogBuffer.head(of: Array(text.utf8)), as: UTF8.self)

		lines.append(LogLine(id: nextID, spans: AnsiParser.spans(in: kept)))
		nextID += 1
		trim()
	}

	public mutating func removeAll() {
		lines = []
	}

	/// The first bytes of a line, cut on a code point boundary so the decoder does not turn
	/// a half character into a replacement that is longer than what it replaced.
	static func head<Bytes: Collection>(of bytes: Bytes) -> Bytes.SubSequence
	where Bytes.Element == UInt8, Bytes.Index == Int {
		guard bytes.count > longestLine else { return bytes[bytes.startIndex...] }

		var end = bytes.startIndex + longestLine

		while end > bytes.startIndex, bytes[end] & 0b1100_0000 == 0b1000_0000 {
			end -= 1
		}

		return bytes[bytes.startIndex ..< end]
	}

	private mutating func trim() {
		guard lines.count > limit else { return }
		lines.removeFirst(lines.count - limit)
	}
}
