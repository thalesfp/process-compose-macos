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
		let kept = text.count > Self.longestLine ? String(text.prefix(Self.longestLine)) + "…" : text

		lines.append(LogLine(id: nextID, spans: AnsiParser.spans(in: kept)))
		nextID += 1
		trim()
	}

	public mutating func removeAll() {
		lines = []
	}

	private mutating func trim() {
		guard lines.count > limit else { return }
		lines.removeFirst(lines.count - limit)
	}
}
