import ProcessComposeCore
import SwiftUI

struct SettingsView: View {
	let server: ServerSupervisor
	let quit: QuitCoordinator

	var body: some View {
		TabView {
			ServerSettings(server: server, quit: quit)
				.tabItem { Label("Server", systemImage: "network") }
			LogSettings()
				.tabItem { Label("Logs", systemImage: "text.alignleft") }
		}
		.frame(width: 460, height: 260)
	}
}

private struct ServerSettings: View {
	let server: ServerSupervisor
	let quit: QuitCoordinator

	@AppStorage(PreferenceKey.host) private var host = PreferenceDefault.host
	@AppStorage(PreferenceKey.port) private var port = PreferenceDefault.port
	@AppStorage(PreferenceKey.mcpPort) private var mcpPort = PreferenceDefault.mcpPort

	@State private var draftHost = ""
	@State private var draftPort = 0
	@State private var draftMCPPort = 0
	@State private var isConfirmingMove = false

	var body: some View {
		Form {
			Section {
				TextField("Host", text: $draftHost)
				TextField("Port", value: $draftPort, format: .number.grouping(.never))
				TextField("MCP port", value: $draftMCPPort, format: .number.grouping(.never))

				HStack {
					Spacer(minLength: 0)
					Button("Apply") { requestApply() }
						.disabled(!hasChanges || quit.isQuitting)
				}
			} footer: {
				Text("PC_PORT_NUM sets the port the first time the app runs. What you apply here wins from then on. The MCP port is the one in the stack's mcp_server block; process-compose serves it at /sse.")
					.font(.callout)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
		.onSubmit { requestApply() }
		.confirmationDialog("Stop the stack to change the address?", isPresented: $isConfirmingMove) {
			Button("Stop and Apply", role: .destructive) { apply() }
		} message: {
			Text("The app started this server. Moving to another address stops it and every process it is running.")
		}
		.task {
			draftHost = host
			draftPort = port
			draftMCPPort = mcpPort
		}
	}

	private var hasChanges: Bool {
		draftHost != host || draftPort != port || draftMCPPort != mcpPort
	}

	// A half-typed port names a different server, and pointing the app at one retires the
	// server it started for the last, so these only take effect once they are asked for.
	private func requestApply() {
		guard hasChanges, !quit.isQuitting else { return }

		let target = ServerAddress(host: draftHost, port: draftPort)

		guard server.wouldStop(movingTo: target) else { return apply() }

		isConfirmingMove = true
	}

	private func apply() {
		host = draftHost
		port = draftPort
		mcpPort = draftMCPPort
	}
}

private struct LogSettings: View {
	@AppStorage(PreferenceKey.logFontSize) private var fontSize = LogFont.standard
	@AppStorage(PreferenceKey.logBufferLines) private var bufferLines = PreferenceDefault.logBufferLines
	@AppStorage(PreferenceKey.logBackfill) private var backfill = PreferenceDefault.logBackfill
	@AppStorage(PreferenceKey.asksBeforeClearingLog) private var asksBeforeClearingLog = true

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
				Toggle("Ask before clearing a log", isOn: $asksBeforeClearingLog)
			} footer: {
				Text("The app keeps this many lines per process in memory and asks the server to replay the newest ones when a log opens.")
					.font(.callout)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
	}
}
