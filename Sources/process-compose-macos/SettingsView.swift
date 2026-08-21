import AppKit
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
		.frame(width: 460, height: 230)
	}
}

private struct ServerSettings: View {
	@AppStorage(PreferenceKey.host) private var host = PreferenceDefault.host
	@AppStorage(PreferenceKey.port) private var port = PreferenceDefault.port
	@AppStorage(PreferenceKey.mcpPort) private var mcpPort = PreferenceDefault.mcpPort
	@AppStorage(PreferenceKey.serverBinaryPath) private var binaryPath = PreferenceDefault.serverBinaryPath
	@AppStorage(PreferenceKey.serverConfigPath) private var configPath = PreferenceDefault.serverConfigPath
	@AppStorage(PreferenceKey.serverWorkingDirectory) private var workingDirectory = PreferenceDefault.serverWorkingDirectory

	@State private var validation: ServerValidation?
	@State private var isValidating = false

	var body: some View {
		Form {
			Section {
				TextField("Host", text: $host)
				TextField("Port", value: $port, format: .number.grouping(.never))
				TextField("MCP port", value: $mcpPort, format: .number.grouping(.never))
			} footer: {
				Text("PC_PORT_NUM sets the port the first time the app runs. What you type here wins from then on. The MCP port is the one in the stack's mcp_server block; process-compose serves it at /sse.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			Section {
				PathField("process-compose", path: $binaryPath)
				PathField("Project config", path: $configPath)
				PathField("Working directory", path: $workingDirectory, isDirectory: true)

				HStack(alignment: .firstTextBaseline, spacing: 10) {
					Button("Validate") { validate() }
						.controlSize(.small)
						.disabled(plan == nil || isValidating)
					validationReadout
					Spacer(minLength: 0)
				}
			} footer: {
				Text("With the binary and the config set, the app starts the server itself when nothing answers the port, and stops it again when the app quits. A server that is already running is left alone, and the app takes the config from it the first time it connects. Working directory is where process-compose runs, which is what a config's working_dir and watch paths are relative to; empty means the config's own directory.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
	}
}

private struct PathField: View {
	private let title: String
	private let isDirectory: Bool
	@Binding private var path: String

	init(_ title: String, path: Binding<String>, isDirectory: Bool = false) {
		self.title = title
		self._path = path
		self.isDirectory = isDirectory
	}

	var body: some View {
		HStack(spacing: 8) {
			TextField(title, text: $path)
				.truncationMode(.head)
			Button("Choose") { choose() }
				.controlSize(.small)
		}
	}

	private func choose() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = !isDirectory
		panel.canChooseDirectories = isDirectory
		panel.allowsMultipleSelection = false
		panel.prompt = "Choose"
		panel.message = title
		if !path.isEmpty {
			panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
		}

		guard panel.runModal() == .OK, let url = panel.url else { return }

		path = url.path
	}
}

extension ServerSettings {
	fileprivate var plan: ServerLaunchPlan? {
		ServerLaunchPlan(
			executablePath: binaryPath,
			configurationPath: configPath,
			workingDirectoryPath: workingDirectory,
			port: port
		)
	}

	@ViewBuilder
	fileprivate var validationReadout: some View {
		switch validation {
		case .valid:
			Label("The config loads", systemImage: "checkmark.circle.fill")
				.foregroundStyle(.green)
				.font(.caption)
		case .failed(let reason):
			Label(reason, systemImage: "exclamationmark.triangle.fill")
				.foregroundStyle(.orange)
				.font(.caption)
				.multilineTextAlignment(.leading)
				.textSelection(.enabled)
		case nil:
			EmptyView()
		}
	}

	fileprivate func validate() {
		guard let plan else { return }

		isValidating = true
		validation = nil

		Task {
			validation = await LiveServerRunner().validate(plan)
			isValidating = false
		}
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
