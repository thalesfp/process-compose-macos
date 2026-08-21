import Foundation

/// The pixel size of the log text. `LogPane` renders at this size; the View menu and
/// Settings step it inside this range.
public enum LogFont {
	public static let range: ClosedRange<Double> = 10 ... 24
	public static let standard: Double = 14

	public static func stepped(_ size: Double, by delta: Double) -> Double {
		min(max(size + delta, range.lowerBound), range.upperBound)
	}
}

/// What a log view must do to catch up with the buffer: drop some already-drawn lines
/// off the front, then append the rest.
public struct LogRenderPlan: Sendable, Equatable {
	public let dropLeading: Int
	public let append: [LogLine]

	public init(dropLeading: Int, append: [LogLine]) {
		self.dropLeading = dropLeading
		self.append = append
	}

	public var isEmpty: Bool { dropLeading == 0 && append.isEmpty }
}

public enum LogRendering {
	/// Diffs the drawn line ids against the buffer. `LogViewModel` only ever trims from
	/// the front and appends to the back, so a matching run means the rest is an append.
	public static func plan(rendered: [Int], lines: [LogLine]) -> LogRenderPlan {
		guard let oldest = lines.first?.id else {
			return LogRenderPlan(dropLeading: rendered.count, append: [])
		}

		let dropLeading = rendered.prefix { $0 < oldest }.count
		let kept = rendered.dropFirst(dropLeading)

		guard kept.elementsEqual(lines.prefix(kept.count), by: { $0 == $1.id }) else {
			return LogRenderPlan(dropLeading: rendered.count, append: lines)
		}

		return LogRenderPlan(dropLeading: dropLeading, append: Array(lines.dropFirst(kept.count)))
	}
}
