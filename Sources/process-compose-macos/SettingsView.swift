import ProcessComposeCore
import SwiftUI

struct SettingsView: View {
	var body: some View {
		TabView {
			ServerSettings()
				.tabItem { Label("Server", systemImage: "network") }
			LogSettings()
				.tabItem { Label("Logs", systemImage: "text.alignleft") }
		}
		.frame(width: 460, height: 200)
	}
}

private struct ServerSettings: View {
	@AppStorage(PreferenceKey.host) private var host = PreferenceDefault.host
	@AppStorage(PreferenceKey.port) private var port = PreferenceDefault.port

	var body: some View {
		Form {
			Section {
				TextField("Host", text: $host)
				TextField("Port", value: $port, format: .number.grouping(.never))
			} footer: {
				Text("PC_PORT_NUM sets the port the first time the app runs. What you type here wins from then on.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
	}
}

private struct LogSettings: View {
	@AppStorage(PreferenceKey.logFontSize) private var fontSize = LogFont.standard
	@AppStorage(PreferenceKey.logBufferLines) private var bufferLines = PreferenceDefault.logBufferLines
	@AppStorage(PreferenceKey.logBackfill) private var backfill = PreferenceDefault.logBackfill

	var body: some View {
		Form {
			Section {
				LabeledContent("Text size") {
					HStack(spacing: 10) {
						Slider(
							value: $fontSize,
							in: LogFont.range,
							step: 1
						)
						Text("\(Int(fontSize)) pt")
							.font(.callout.monospacedDigit())
							.foregroundStyle(.secondary)
					}
				}

				TextField("Lines kept", value: $bufferLines, format: .number)
				TextField("Lines replayed on open", value: $backfill, format: .number)
			} footer: {
				Text("The app keeps this many lines per process in memory and asks the server to replay the newest ones when a log opens.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
	}
}
