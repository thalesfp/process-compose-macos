import Foundation

/// Where the draggable divider sits between two stacked panes.
public enum SplitLayout {
	/// How far one View menu step moves the divider, and how far it may be moved. The
	/// menu cannot see the window height, so the bound is on the fraction rather than
	/// on points; `topHeight` still holds each pane to its own minimum when it draws.
	public static let step = 0.05
	public static let fractionRange: ClosedRange<Double> = 0.15 ... 0.85

	public static func stepped(_ fraction: Double, by delta: Double) -> Double {
		min(max(fraction + delta, fractionRange.lowerBound), fractionRange.upperBound)
	}

	/// Whether a step would move the divider at all. A drag is bounded in points rather
	/// than by `fractionRange`, so a stored fraction can sit outside it, and a step back
	/// towards the range moves even from an end the range calls the limit.
	public static func canStep(_ fraction: Double, by delta: Double) -> Bool {
		stepped(fraction, by: delta) != fraction
	}

	public static func topHeight(
		fraction: Double,
		total: Double,
		minTop: Double,
		minBottom: Double
	) -> Double {
		let bounds = bounds(total: total, minTop: minTop, minBottom: minBottom)
		return min(max(fraction * total, bounds.lowerBound), bounds.upperBound)
	}

	/// The fraction to store after the divider is dragged by `translation` points.
	public static func fraction(
		startFraction: Double,
		translation: Double,
		total: Double,
		minTop: Double,
		minBottom: Double
	) -> Double {
		guard total > 0 else { return startFraction }

		let start = topHeight(fraction: startFraction, total: total, minTop: minTop, minBottom: minBottom)
		let bounds = bounds(total: total, minTop: minTop, minBottom: minBottom)

		return min(max(start + translation, bounds.lowerBound), bounds.upperBound) / total
	}

	private static func bounds(total: Double, minTop: Double, minBottom: Double) -> ClosedRange<Double> {
		let lower = min(minTop, max(total, 0))
		return lower ... max(total - minBottom, lower)
	}
}
