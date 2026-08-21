import ProcessComposeCore
import SwiftUI

/// The verdict on a config, shown next to whatever asked for it.
struct ValidationReadout: View {
	let validation: ServerValidation?

	var body: some View {
		switch validation {
		case .valid:
			label("The config loads", systemImage: "checkmark.circle.fill", color: .green)
		case .failed(let reason):
			label(reason, systemImage: "exclamationmark.triangle.fill", color: .orange)
		case nil:
			EmptyView()
		}
	}

	private func label(_ text: String, systemImage: String, color: Color) -> some View {
		Label(text, systemImage: systemImage)
			.foregroundStyle(color)
			.font(.caption)
			.multilineTextAlignment(.leading)
			.textSelection(.enabled)
	}
}
