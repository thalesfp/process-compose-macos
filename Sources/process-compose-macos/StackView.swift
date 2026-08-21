import AppKit
import ProcessComposeCore
import SwiftUI

struct StackView: View {
	@Bindable var model: StackViewModel
	@Bindable var logModel: LogViewModel
	let mcpModel: MCPServerViewModel

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.accessibilityReduceTransparency) private var reduceTransparency

	@AppStorage(PreferenceKey.host) private var host = PreferenceDefault.host
	@AppStorage(PreferenceKey.port) private var port = PreferenceDefault.port
	@AppStorage(PreferenceKey.mcpPort) private var mcpPort = PreferenceDefault.mcpPort
	@AppStorage(PreferenceKey.logBufferLines) private var bufferLines = PreferenceDefault.logBufferLines
	@AppStorage(PreferenceKey.logBackfill) private var backfill = PreferenceDefault.logBackfill

	var body: some View {
		VerticalSplit(minTopHeight: 180, minBottomHeight: 140) {
			content
		} bottom: {
			LogPane(model: logModel)
		}
		.overlay(alignment: .bottom) { errorBar }
		.animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.lastError)
		.navigationTitle(model.project?.projectName ?? "Process Compose")
		.navigationSubtitle(subtitle)
		.toolbar { toolbar }
		.onChange(of: bufferLines, initial: true) { _, lines in logModel.maxLines = lines }
		.onChange(of: backfill, initial: true) { _, lines in logModel.backfill = lines }
		.onChange(of: address, initial: true) { _, _ in reconnect() }
		.onChange(of: mcpAddress, initial: true) { _, mcp in mcpModel.watch(mcp) }
		.onChange(of: model.selection) { _, name in logModel.select(name) }
		.confirmationDialog(
			"Stop every running process?",
			isPresented: $model.isConfirmingStopStack
		) {
			Button("Stop the stack", role: .destructive) {
				Task { await model.stopStack() }
			}
		}
	}

	@ToolbarContentBuilder
	private var toolbar: some ToolbarContent {
		ToolbarItem(placement: .status) {
			HStack(spacing: 12) {
				statusDot(
					isConnected ? "Connected" : "Offline",
					color: isConnected ? .green : .red,
					describedBy: isConnected ? "Connected to the server" : "Not connected to the server"
				)

				if isConnected {
					Divider()
						.frame(height: 12)
					usageReadout
				}

				Divider()
					.frame(height: 12)
				mcpReadout
			}
		}

		ToolbarItem(placement: .primaryAction) {
			powerControl
		}
	}

	private func statusDot(_ label: String, color: Color, describedBy description: String) -> some View {
		HStack(spacing: 6) {
			Circle()
				.fill(color)
				.frame(width: 8, height: 8)
			Text(label)
				.font(.callout)
				.foregroundStyle(.secondary)
		}
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(description)
	}

	private var mcpReadout: some View {
		let help = mcpHelp

		return statusDot("MCP", color: mcpModel.isReachable ? .green : .secondary, describedBy: help)
			.help(help)
			.contextMenu { CopyMCPURLButton(mcpModel: mcpModel) }
	}

	private var mcpHelp: String {
		guard let url = mcpModel.url else { return "Settings has no usable MCP port" }
		return mcpModel.isReachable
			? "MCP server answering at \(url.absoluteString)"
			: "No MCP server at \(url.absoluteString)"
	}

	@ViewBuilder
	private var powerControl: some View {
		if model.isChangingStack {
			ProgressView()
				.controlSize(.small)
				.accessibilityLabel("Working on the stack")
		} else {
			Button(powerTitle, systemImage: "power") { model.togglePower() }
			.labelStyle(.titleAndIcon)
			.disabled(!model.canChangePower)
			.help(model.power == .canStop ? "Stop every running process" : "Start every process the stack defines")
		}
	}

	private var powerTitle: String {
		model.power == .canStop ? "Stop Stack" : "Start Stack"
	}

	@ViewBuilder
	private var content: some View {
		if case .disconnected(let reason) = model.connection {
			ContentUnavailableView {
				Label("No stack running", systemImage: "bolt.horizontal.circle")
			} description: {
				Text(reason)
				Text("Start it with `make up` in acme. The app reconnects on its own.")
					.font(.callout)
			}
		} else if model.processes.isEmpty {
			ProgressView("Connecting")
				.frame(maxWidth: .infinity, maxHeight: .infinity)
		} else {
			List(selection: $model.selection) {
				ForEach(model.sections) { section in
					Section {
						ForEach(section.processes) { state in
							row(for: state, kind: section.kind)
						}
					} header: {
						sectionHeader(for: section)
					}
				}
			}
			.listStyle(.inset)
		}
	}

	/// Project, namespace and role, each shown only where it changes, so the reader
	/// sees four levels without four repeated lines on every section.
	/// The row and its context menu share one set of actions, so the two can never
	/// offer different things for the same process.
	private func row(for state: ProcessState, kind: ProcessKind) -> some View {
		let name = state.name
		let start: () -> Void = { Task { await model.startProcess(name) } }
		let stop: () -> Void = { Task { await model.stopProcess(name) } }
		let restart: () -> Void = { Task { await model.restartProcess(name) } }

		return ProcessRow(
			state: state,
			kind: kind,
			isBusy: model.isBusy(name),
			start: start,
			stop: stop,
			restart: restart
		)
		.tag(name)
		.contextMenu {
			Button("Start", action: start)
				.disabled(!model.canStart(name))
			Button("Restart", action: restart)
				.disabled(!model.canStop(name))
			Button("Stop", action: stop)
				.disabled(!model.canStop(name))
			Divider()
			Button("Show Log") { model.selection = name }
			Button("Copy Name") { NSPasteboard.copy(name) }
		}
	}

	private func sectionHeader(for section: StackSection) -> some View {
		// A pinned header only reserves the height of its content, so the breathing room
		// goes on the labels themselves. Padding the container makes it cover the first row.
		VStack(alignment: .leading, spacing: 6) {
			if let project = section.project, section.isFirstInProject {
				Text(project)
					.font(.title2.weight(.bold))
					.foregroundStyle(.primary)
					.padding(.top, 16)
			}
			if section.isFirstInNamespace {
				Text(section.namespace)
					.font(.title3.weight(.semibold))
					.foregroundStyle(.secondary)
					.padding(.top, section.isFirstInProject ? 0 : 14)
					.padding(.leading, section.project == nil ? 0 : 10)
			}
			if section.showsKind {
				Text(section.kind.label)
					.font(.body.weight(.medium))
					.foregroundStyle(.tertiary)
					.padding(.top, section.isFirstInNamespace ? 0 : 14)
					.padding(.leading, section.project == nil ? 10 : 20)
			}
		}
		.textCase(nil)
		.frame(maxWidth: .infinity, alignment: .leading)
	}


	@ViewBuilder
	private var errorBar: some View {
		if let message = model.lastError {
			HStack(spacing: 8) {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange)
				Text(message)
					.font(.callout)
					.textSelection(.enabled)
				Spacer(minLength: 12)
				Button("Dismiss") { model.dismissError() }
					.controlSize(.small)
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
			.background(errorBackground, in: RoundedRectangle(cornerRadius: 8))
			.overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
			.padding(12)
			.transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
		}
	}

	private var errorBackground: AnyShapeStyle {
		reduceTransparency
			? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
			: AnyShapeStyle(.regularMaterial)
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

	private var subtitle: String {
		guard let project = model.project else { return "Not connected" }
		let running = "\(model.runningCount) of \(model.processCount) running"
		guard let uptime = model.uptime else { return "\(running)  ·  \(project.version)" }
		return "\(running)  ·  up \(uptime.compactLabel)  ·  \(project.version)"
	}

	private var address: ServerAddress? {
		ServerAddress(host: host, port: port)
	}

	private var mcpAddress: ServerAddress? {
		ServerAddress(host: host, port: mcpPort)
	}

	private var isConnected: Bool {
		model.connection == .connected
	}

	private func reconnect() {
		guard let address else {
			// The log pane keeps its own client, so releasing it is what stops Clear from
			// truncating logs on the server the user just navigated away from.
			model.refuseAddress("Settings has no usable server address for \(host):\(port)")
			logModel.select(nil)
			return
		}

		let client = LiveProcessComposeClient(address: address)
		model.use(client)
		logModel.use(client)
	}
}
