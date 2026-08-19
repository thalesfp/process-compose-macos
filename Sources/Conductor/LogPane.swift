import ConductorCore
import SwiftUI

struct LogPane: View {
	@Bindable var model: LogViewModel

	@AppStorage(PreferenceKey.logFontSize) private var fontSize = LogFont.standard

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			output
		}
	}

	private var header: some View {
		HStack(spacing: 10) {
			Image(systemName: "text.alignleft")
				.foregroundStyle(.secondary)
				.accessibilityHidden(true)

			Text(model.selected ?? "No process selected")
				.font(.system(.callout, design: .monospaced))
				.fontWeight(.medium)
				.lineLimit(1)

			if model.isStreaming {
				Circle()
					.fill(.green)
					.frame(width: 7, height: 7)
					.help("Following the live stream")
					.accessibilityLabel("Streaming")
			}

			Spacer(minLength: 12)

			if let error = model.lastError {
				Text(error)
					.font(.caption)
					.foregroundStyle(.orange)
					.lineLimit(1)
			}

			Text("\(model.lines.count) lines")
				.font(.caption.monospacedDigit())
				.foregroundStyle(.secondary)

			Toggle("Follow", isOn: $model.isFollowing)
				.toggleStyle(.switch)
				.controlSize(.small)
				.font(.caption)

			Button("Clear") { Task { await model.clear() } }
				.controlSize(.small)
				.disabled(model.selected == nil)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 7)
	}

	@ViewBuilder
	private var output: some View {
		if model.selected == nil {
			Text("Select a process to read its output")
				.font(.callout)
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(Color(nsColor: .textBackgroundColor))
		} else {
			LogTextView(lines: model.lines, fontSize: fontSize, isFollowing: model.isFollowing)
		}
	}
}
