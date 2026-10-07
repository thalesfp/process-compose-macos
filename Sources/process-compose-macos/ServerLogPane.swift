import ProcessComposeCore
import SwiftUI

/// The server's own output, in the pane the process logs use.
struct ServerLogPane: View {
	let log: ServerLog
	let status: String
	let windowState: WindowState
	let close: () -> Void

	@AppStorage(PreferenceKey.logFontSize) private var fontSize = LogFont.standard

	@State private var isFollowing = true
	@State private var filter = ""
	@FocusState private var isFilterFocused: Bool

	var body: some View {
		let visible = LogFilter.matching(log.lines, filter: filter)

		return VStack(spacing: 0) {
			header(visible: visible.count)
			Divider()
			output(visible)
		}
		.onChange(of: windowState.filterFocusToken) { isFilterFocused = true }
	}

	private func header(visible: Int) -> some View {
		HStack(spacing: 10) {
			Image(systemName: "server.rack")
				.foregroundStyle(.secondary)
				.accessibilityHidden(true)

			Text("Server")
				.font(.system(.callout, design: .monospaced))
				.fontWeight(.medium)

			Text(status)
				.font(.callout)
				.foregroundStyle(.secondary)
				.lineLimit(1)

			Spacer(minLength: 12)

			LogFilterField(text: $filter, isFocused: $isFilterFocused)

			Text(LogFilter.countLabel(visible: visible, total: log.lines.count, filter: filter))
				.font(.callout.monospacedDigit())
				.foregroundStyle(.secondary)

			Toggle("Follow", isOn: $isFollowing)
				.toggleStyle(.switch)
				.font(.callout)

			Button("Clear") { log.clear() }

			Button("Close", systemImage: "xmark", action: close)
				.labelStyle(.iconOnly)
				.help("Back to the process log")
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 7)
	}

	@ViewBuilder
	private func output(_ visible: [LogLine]) -> some View {
		if log.lines.isEmpty {
			LogPlaceholder("The app has not started a server, so there is nothing to read here")
		} else {
			FilteredLog(lines: visible, filter: filter, fontSize: fontSize, isFollowing: isFollowing)
		}
	}
}
