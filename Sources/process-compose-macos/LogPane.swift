import ProcessComposeCore
import SwiftUI

struct LogPane: View {
	@Bindable var model: LogViewModel
	let windowState: WindowState

	@AppStorage(PreferenceKey.logFontSize) private var fontSize = LogFont.standard

	@FocusState private var isFilterFocused: Bool

	var body: some View {
		// Filtering walks the whole buffer, so it is done once here rather than by each
		// part of the pane that needs the result.
		let visible = model.visibleLines

		return VStack(spacing: 0) {
			header(visible: visible.count)
			Divider()
			output(visible)
		}
		.onChange(of: windowState.filterFocusToken) { isFilterFocused = true }
	}

	private func header(visible: Int) -> some View {
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

			Text(LogFilter.countLabel(visible: visible, total: model.lines.count, filter: model.filter))
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
	private func output(_ visible: [LogLine]) -> some View {
		if model.selected == nil {
			LogPlaceholder("Select a process to read its output")
		} else {
			FilteredLog(lines: visible, filter: model.filter, fontSize: fontSize, isFollowing: model.isFollowing)
		}
	}
}

/// The filtered body both log panes show, and what it says when a filter keeps nothing.
struct FilteredLog: View {
	let lines: [LogLine]
	let filter: String
	let fontSize: Double
	let isFollowing: Bool

	var body: some View {
		if lines.isEmpty, !filter.isEmpty {
			LogPlaceholder("No lines match \"\(filter)\"")
		} else {
			LogTextView(lines: lines, fontSize: fontSize, isFollowing: isFollowing)
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
