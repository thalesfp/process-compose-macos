import ProcessComposeCore
import SwiftUI

struct LogPane: View {
	@Bindable var model: LogViewModel
	let windowState: WindowState

	@AppStorage(PreferenceKey.logFontSize) private var fontSize = LogFont.standard

	@FocusState private var isFilterFocused: Bool

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			output
		}
		.onChange(of: windowState.filterFocusToken) { isFilterFocused = true }
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

			LogFilterField(text: $model.filter, isFocused: $isFilterFocused)

			Text(countLabel)
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

	private var countLabel: String {
		model.filter.isEmpty
			? "\(model.lines.count) lines"
			: "\(model.visibleLines.count) of \(model.lines.count) lines"
	}

	@ViewBuilder
	private var output: some View {
		if model.selected == nil {
			LogPlaceholder("Select a process to read its output")
		} else if model.visibleLines.isEmpty, !model.filter.isEmpty {
			LogPlaceholder("No lines match \"\(model.filter)\"")
		} else {
			LogTextView(lines: model.visibleLines, fontSize: fontSize, isFollowing: model.isFollowing)
		}
	}
}

/// The filter box both log panes carry.
struct LogFilterField: View {
	@Binding var text: String
	@FocusState.Binding var isFocused: Bool

	var body: some View {
		TextField("Filter", text: $text)
			.textFieldStyle(.roundedBorder)
			.controlSize(.small)
			.font(.caption)
			.frame(width: 160)
			.focused($isFocused)
			.accessibilityLabel("Filter the log")
	}
}

/// What a log pane shows in place of output.
struct LogPlaceholder: View {
	private let text: String

	init(_ text: String) {
		self.text = text
	}

	var body: some View {
		Text(text)
			.font(.callout)
			.foregroundStyle(.secondary)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(Color(nsColor: .textBackgroundColor))
	}
}
