import AppKit
import ProcessComposeCore
import SwiftUI

struct ConnectionReadouts: View {
	let model: StackViewModel
	let mcpModel: MCPServerViewModel
	let server: ServerSupervisor
	let windowState: WindowState
	let serverStatus: String

	var body: some View {
		HStack(spacing: 12) {
			statusDot(
				isConnected ? "Connected" : "Offline",
				color: isConnected ? .green : .red,
				describedBy: isConnected ? "Connected to the server" : "Not connected to the server"
			)

			if isConnected {
				if let uptime = model.uptime {
					Divider()
						.frame(height: 12)
					uptimeReadout(uptime)
				}

				Divider()
					.frame(height: 12)
				usageReadout
			}

			Divider()
				.frame(height: 12)
			serverReadout

			Divider()
				.frame(height: 12)
			mcpReadout
		}
	}

	private func statusDot(
		_ label: String,
		signal: StatusSignal = .on,
		color: Color,
		describedBy description: String
	) -> some View {
		Label {
			Text(label)
				.font(.callout)
				.foregroundStyle(.secondary)
		} icon: {
			StatusMark(signal: signal, color: color)
		}
		.labelStyle(.titleAndIcon)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(description)
	}

	private var mcpReadout: some View {
		let help = mcpHelp

		return Menu {
			Text(mcpHelp)

			Divider()

			Button("Copy MCP URL") { mcpModel.url.map { NSPasteboard.copy($0.absoluteString) } }
				.disabled(mcpModel.url == nil)
		} label: {
			statusDot(
				"MCP",
				signal: mcpModel.isReachable ? .on : .off,
				color: mcpModel.isReachable ? .green : .secondary,
				describedBy: help
			)
		}
		.menuIndicator(.hidden)
		.fixedSize()
		.help(help)
	}

	private var serverReadout: some View {
		let help = serverStatus

		return Menu {
			Text(help)

			Divider()

			Button("Start Server") { Task { await server.start() } }
				.disabled(!server.canStart)

			Button("Stop Server…") { model.ask(.stopServer(identity: server.identity)) }
				.disabled(!server.isOwned)

			Button("Set Up Server…") { windowState.isSettingUpServer = true }

			Divider()

			Button(windowState.isShowingServerLog ? "Hide Server Log" : "Show Server Log") {
				windowState.isShowingServerLog.toggle()
			}

			Button("Show Config in Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.configURLs) }
				.disabled(model.configURLs.isEmpty)
		} label: {
			statusDot("Server", signal: serverSignal, color: serverColor, describedBy: help)
		}
		.menuIndicator(.hidden)
		.fixedSize()
		.help(help)
	}

	private var serverSignal: StatusSignal {
		switch server.state {
		case .running: .on
		case .failed: .failed
		case .idle, .unconfigured, .remote: .off
		}
	}

	private var serverColor: Color {
		switch server.state {
		case .running: .green
		case .failed: .orange
		case .idle, .unconfigured, .remote: .secondary
		}
	}

	private func uptimeReadout(_ uptime: Duration) -> some View {
		let label = uptime.compactLabel

		return Label(label, systemImage: "clock")
			.labelStyle(.titleAndIcon)
			.font(.callout.monospacedDigit())
			.foregroundStyle(.secondary)
			.fixedSize()
			.accessibilityElement(children: .ignore)
			.accessibilityLabel("The server has been up for \(label)")
			.help("Time since the server started")
	}

	/// Totals across every running process. A second `.status` toolbar item would be
	/// collapsed into the overflow menu, so this lives inside the connection item.
	private var usageReadout: some View {
		let cpu = model.usage.cpuLabel
		let memory = model.usage.memoryLabel

		return HStack(spacing: 12) {
			Label(cpu, systemImage: "cpu")
			Label(memory, systemImage: "memorychip")
		}
		.labelStyle(.titleAndIcon)
		.font(.callout.monospacedDigit())
		.foregroundStyle(.secondary)
		.fixedSize()
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(
			"The stack is using \(cpu) processor and \(memory) memory"
		)
		.help("Total across every running process")
	}

	private var mcpHelp: String {
		guard let url = mcpModel.url else { return "Settings has no usable MCP port" }
		return mcpModel.isReachable
			? "MCP server answering at \(url.absoluteString)"
			: "No MCP server at \(url.absoluteString)"
	}

	private var isConnected: Bool {
		model.connection == .connected
	}
}
