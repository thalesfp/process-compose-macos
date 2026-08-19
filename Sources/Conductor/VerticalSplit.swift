import ConductorCore
import SwiftUI

/// Two stacked panes with a divider the user drags. The split survives relaunch,
/// which is the one thing `VSplitView` cannot do.
struct VerticalSplit<Top: View, Bottom: View>: View {
	let minTopHeight: Double
	let minBottomHeight: Double
	@ViewBuilder let top: () -> Top
	@ViewBuilder let bottom: () -> Bottom

	@AppStorage(PreferenceKey.splitFraction) private var fraction = PreferenceDefault.splitFraction
	@State private var fractionAtDragStart: Double?

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
					let start = fractionAtDragStart ?? fraction
					fractionAtDragStart = start
					fraction = SplitLayout.fraction(
						startFraction: start,
						translation: value.translation.height,
						total: total,
						minTop: minTopHeight,
						minBottom: minBottomHeight
					)
				}
				.onEnded { _ in fractionAtDragStart = nil }
		)
		.accessibilityLabel("Resize the log pane")
	}
}
