import Foundation

/// Where the draggable divider sits between two stacked panes.
public enum SplitLayout {
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
