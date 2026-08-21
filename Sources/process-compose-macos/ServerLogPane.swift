import ProcessComposeCore
import SwiftUI

/// The server's own output, in the pane the process logs use.
struct ServerLogPane: View {
	let log: ServerLog
	let status: String
	let close: () -> Void

	@AppStorage(PreferenceKey.logFontSize) private var fontSize = LogFont.standard

	@State private var isFollowing = true

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			output
		}
	}

	private var header: some View {
		HStack(spacing: 10) {
			Image(systemName: "server.rack")
				.foregroundStyle(.secondary)
				.accessibilityHidden(true)

			Text("Server")
				.font(.system(.callout, design: .monospaced))
				.fontWeight(.medium)

			Text(status)
				.font(.caption)
				.foregroundStyle(.secondary)
				.lineLimit(1)

			Spacer(minLength: 12)

			Text("\(log.lines.count) lines")
				.font(.caption.monospacedDigit())
				.foregroundStyle(.secondary)

			Toggle("Follow", isOn: $isFollowing)
				.toggleStyle(.switch)
				.controlSize(.small)
				.font(.caption)

			Button("Clear") { log.clear() }
				.controlSize(.small)

			Button("Close", systemImage: "xmark", action: close)
				.labelStyle(.iconOnly)
				.controlSize(.small)
				.help("Back to the process log")
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 7)
	}

	@ViewBuilder
	private var output: some View {
		if log.lines.isEmpty {
			LogPlaceholder("The app has not started a server, so there is nothing to read here")
		} else {
			LogTextView(lines: log.lines, fontSize: fontSize, isFollowing: isFollowing)
		}
	}
}
