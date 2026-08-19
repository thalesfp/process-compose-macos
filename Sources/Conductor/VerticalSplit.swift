import ConductorCore
import SwiftUI

/// Two stacked panes with a divider the user drags. The split survives relaunch,
/// which is the one thing `VSplitView` cannot do.
struct VerticalSplit<Top: View, Bottom: View>: View {
	let minTopHeight: Double
	let minBottomHeight: Double
	@ViewBuilder let top: () -> Top
	@ViewBuilder let bottom: () -> Bottom

	@AppStorage(PreferenceKey.splitFraction) private var storedFraction = PreferenceDefault.splitFraction

	/// The divider follows the pointer from `@State`, so a drag is not one UserDefaults
	/// write per tick. The stored value is updated once the drag ends.
	@State private var drag: (start: Double, current: Double)?

	private var fraction: Double {
		drag?.current ?? storedFraction
	}

	var body: some View {
		GeometryReader { proxy in
			let total = proxy.size.height
			let topHeight = SplitLayout.topHeight(
				fraction: fraction,
				total: total,
				minTop: minTopHeight,
				minBottom: minBottomHeight
			)

			VStack(spacing: 0) {
				top()
					.frame(height: topHeight)
				divider(in: total)
				bottom()
					.frame(maxHeight: .infinity)
			}
		}
	}

	private func divider(in total: Double) -> some View {
		ZStack {
			Color.clear
				.contentShape(Rectangle())
			Divider()
		}
		.frame(height: 9)
		.onContinuousHover { phase in
			switch phase {
			case .active: NSCursor.resizeUpDown.set()
			case .ended: NSCursor.arrow.set()
			}
		}
		.gesture(
			DragGesture(coordinateSpace: .global)
				.onChanged { value in
					let start = drag?.start ?? storedFraction
					drag = (
						start,
						SplitLayout.fraction(
							startFraction: start,
							translation: value.translation.height,
							total: total,
							minTop: minTopHeight,
							minBottom: minBottomHeight
						)
					)
				}
				.onEnded { _ in
					if let drag { storedFraction = drag.current }
					drag = nil
				}
		)
		.accessibilityLabel("Resize the log pane")
	}
}
