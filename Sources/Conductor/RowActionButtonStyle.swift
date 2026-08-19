import SwiftUI

/// The start/restart/stop glyphs in a process row. They share one hit target and one
/// optical weight so the three read as a set, and they light up under the pointer.
struct RowActionButtonStyle: ButtonStyle {
	static let size = CGSize(width: 26, height: 22)

	func makeBody(configuration: Configuration) -> some View {
		Glyph(configuration: configuration)
	}

	private struct Glyph: View {
		let configuration: ButtonStyleConfiguration

		@Environment(\.isEnabled) private var isEnabled
		@State private var isHovering = false

		var body: some View {
			configuration.label
				.font(.system(size: 12, weight: .semibold))
				.foregroundStyle(foreground)
				.frame(width: RowActionButtonStyle.size.width, height: RowActionButtonStyle.size.height)
				.background(background, in: RoundedRectangle(cornerRadius: 5))
				.contentShape(RoundedRectangle(cornerRadius: 5))
				.onHover { isHovering = $0 }
		}

		private var foreground: HierarchicalShapeStyle {
			guard isEnabled else { return .quaternary }
			return isHovering || configuration.isPressed ? .primary : .secondary
		}

		private var background: Color {
			guard isEnabled else { return .clear }
			if configuration.isPressed { return .primary.opacity(0.16) }
			return isHovering ? .primary.opacity(0.08) : .clear
		}
	}
}
