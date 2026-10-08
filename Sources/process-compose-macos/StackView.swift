import AppKit
import ProcessComposeCore
import SwiftUI

struct StackView: View {
	@Bindable var model: StackViewModel
	@Bindable var logModel: LogViewModel
	let mcpModel: MCPServerViewModel
	let server: ServerSupervisor
	let quit: QuitCoordinator

	@State private var windowState = WindowState()

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.accessibilityReduceTransparency) private var reduceTransparency

	@AppStorage(PreferenceKey.host) private var host = PreferenceDefault.host
	@AppStorage(PreferenceKey.port) private var port = PreferenceDefault.port
	@AppStorage(PreferenceKey.mcpPort) private var mcpPort = PreferenceDefault.mcpPort
	@AppStorage(PreferenceKey.logBufferLines) private var bufferLines = PreferenceDefault.logBufferLines
	@AppStorage(PreferenceKey.logBackfill) private var backfill = PreferenceDefault.logBackfill
	@AppStorage(PreferenceKey.selectedProject) private var storedProject = ""
	@AppStorage(PreferenceKey.serverBinaryPath) private var binaryPath = PreferenceDefault.serverBinaryPath
	@AppStorage(PreferenceKey.serverConfigPath) private var configPath = PreferenceDefault.serverConfigPath
	@AppStorage(PreferenceKey.serverWorkingDirectory) private var workingDirectory = PreferenceDefault.serverWorkingDirectory
	@AppStorage(PreferenceKey.suggestedConfigPath) private var suggestedConfig = PreferenceDefault.suggestedConfigPath
	@AppStorage(PreferenceKey.sidebarVisible) private var isSidebarVisible = true
	@AppStorage(PreferenceKey.asksBeforeClearingLog) private var asksBeforeClearingLog = true

	var body: some View {
		syncedWithModel
			.task { if !storedProject.isEmpty { model.select(project: storedProject) } }
			.task(id: ServerInputs(address: address, plan: launchPlan)) {
				await server.use(address: address, plan: launchPlan)
			}
			.sheet(isPresented: $windowState.isSettingUpServer) { ServerSetupSheet() }
			.confirmationDialog(
				model.confirmation.map { model.question(for: $0.target) } ?? "",
				isPresented: isConfirming(clearingLog: false),
				presenting: model.confirmation
			) { confirmation in
				answerButton(for: confirmation)
			} message: { confirmation in
				detail(for: confirmation)
			}
	}

	// Swift 6.3 gives up type-checking one modifier chain this long, so it is built in stages.
	private var window: some View {
		NavigationSplitView(columnVisibility: columnVisibility) {
			sidebar
		} detail: {
			detailColumn
		}
		.overlay { if quit.isStopping { stoppingOverlay } }
		.background(StackWindowHook(quit: quit))
		.focusedSceneValue(\.windowState, windowState)
		.navigationTitle(model.project?.projectName ?? "Process Compose")
		.navigationSubtitle(subtitle)
		.toolbar { toolbar }
	}

	private var syncedWithPreferences: some View {
		window
			.onChange(of: bufferLines, initial: true) { _, lines in
				logModel.maxLines = lines
				server.log.maxLines = lines
			}
			.onChange(of: backfill, initial: true) { _, lines in logModel.backfill = lines }
			.onChange(of: address, initial: true) { _, _ in reconnect() }
			.onChange(of: mcpAddress, initial: true) { _, mcp in mcpModel.watch(mcp) }
			.onChange(of: launchPlan, initial: true) { _, plan in model.define(from: plan) }
			.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
				model.refreshDefinition()
			}
	}

	private var syncedWithModel: some View {
		syncedWithPreferences
			.onChange(of: model.selection) { _, name in
				logModel.select(name)
				if name != nil { windowState.isShowingServerLog = false }
			}
			.onChange(of: model.selectedProject) { _, name in storedProject = name ?? "" }
			.onChange(of: model.project?.configFiles ?? []) { _, files in
				ServerLaunchPlan.learnedConfiguration(from: files, current: configPath)
					.map { suggestedConfig = $0 }
			}
			.onChange(of: server.identity) {
				// Whatever was agreed to was agreed for the server that was there when the
				// question was asked, and a restart at the same address is another server.
				model.abandonActions()
			}
			.onChange(of: model.connection) { _, connection in
				switch connection {
				case .connected: Task { await server.attachIfAnswering() }
				case .disconnected: Task { await server.recheck() }
				case .connecting: break
				}
			}
	}

	private var detailColumn: some View {
		VerticalSplit(minTopHeight: 180, minBottomHeight: 140) {
			content
		} bottom: {
			if windowState.isShowingServerLog {
				ServerLogPane(
					log: server.log,
					status: serverStatus,
					windowState: windowState
				) { windowState.isShowingServerLog = false }
			} else {
				LogPane(
					model: logModel,
					windowState: windowState,
					clear: clearLog,
					isConnected: isConnected
				)
			}
		}
		.overlay(alignment: .bottom) { errorBar }
		.animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.lastError)
		// dialogSuppressionToggle reaches every dialog presented within the view it modifies.
		.confirmationDialog(
			model.confirmation.map { model.question(for: $0.target) } ?? "",
			isPresented: isConfirming(clearingLog: true),
			presenting: model.confirmation
		) { confirmation in
			answerButton(for: confirmation)
		} message: { confirmation in
			detail(for: confirmation)
		}
		.dialogSuppressionToggle(isSuppressed: isClearLogQuestionSuppressed)
	}

	/// The dialog is raised by whatever names a target, and dismissing it clears the
	/// name rather than leaving a stop the user backed out of pending.
	private func isConfirming(clearingLog: Bool) -> Binding<Bool> {
		Binding(
			get: { model.confirmation.map { Self.clearsLog($0.target) == clearingLog } ?? false },
			set: { if !$0 { model.confirmation = nil } }
		)
	}

	private static func clearsLog(_ target: ConfirmTarget) -> Bool {
		if case .clearLog = target { return true }
		return false
	}

	private var isClearLogQuestionSuppressed: Binding<Bool> {
		Binding(
			get: { !asksBeforeClearingLog },
			set: { asksBeforeClearingLog = !$0 }
		)
	}

	private func answerButton(for confirmation: Confirmation) -> some View {
		Button(model.answer(for: confirmation.target), role: confirmation.target.isDestructive ? .destructive : nil) {
			Task { await answer(confirmation) }
		}
	}

	@ViewBuilder
	private func detail(for confirmation: Confirmation) -> some View {
		if let detail = ConfirmationWording.detail(for: confirmation.target) {
			Text(detail)
		}
	}

	/// The server and the log are not the stack model's, so the window acts on those two.
	private func answer(_ confirmation: Confirmation) async {
		switch confirmation.target {
		case .stopServer(let identity):
			await server.stop(expecting: identity)
		case .clearLog(let name):
			let isStanding = model.isStanding(confirmation)
			let isSameLog = logModel.selected == name

			guard isStanding, isSameLog else { return }

			await logModel.clear()
		case .stopStack, .stopProject, .startProject:
			await model.perform(confirmation)
		}
	}

	private var clearLog: ClearLogAction {
		ClearLogAction(model: model, logModel: logModel, asks: asksBeforeClearingLog)
	}

	/// The toolbar button and the View menu item both collapse the sidebar, so the
	/// column reads its state from the preference the menu writes.
	private var columnVisibility: Binding<NavigationSplitViewVisibility> {
		Binding(
			get: { isSidebarVisible ? .all : .detailOnly },
			set: { isSidebarVisible = $0 != .detailOnly }
		)
	}

	/// The projects, one row each. Exactly one is selected, so clicking the empty space
	/// below the rows leaves the list where it is.
	private var sidebar: some View {
		let selection = Binding<String?>(
			get: { model.selectedProject },
			set: { name in name.map { model.select(project: $0) } }
		)

		return List(selection: selection) {
			ForEach(model.projects) { project in
				Text(project.name)
					.lineLimit(1)
					.truncationMode(.middle)
					.badge(Text("\(project.runningCount)/\(project.processCount)").monospacedDigit())
					.tag(project.name)
					.accessibilityElement(children: .ignore)
					.accessibilityLabel(
						"\(project.name), \(project.runningCount) of \(project.processCount) running"
					)
					.contextMenu {
						ProjectActions(model: model, project: project.name)
						Divider()
						Button("Copy Name") { NSPasteboard.copy(project.name) }
					}
			}
		}
		.navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 300)
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

		// macOS 27 packs a .primaryAction item against a centered .status item without this.
		ToolbarItem(placement: .automatic) {
			Spacer()
		}

		ToolbarItem(placement: .primaryAction) {
			powerControl
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

	/// A server the app tried and failed to start says so here, since the empty state is
	/// where the user is looking.
	private var serverAdvice: String {
		switch server.state {
		case .failed(let reason): reason
		case .unconfigured:
			suggestedConfig.isEmpty
				? "Choose the config for this stack and the app starts it from here. It reconnects on its own if you run the stack yourself."
				: "Set the server up to start this stack from here. It reconnects on its own if you run the stack yourself."
		case .remote:
			"The app only starts a server on this machine. Run the stack on \(host), or point Settings at localhost."
		case .idle:
			"Start the stack here, or run it yourself and the app picks it up."
		case .running:
			"The app connects as soon as the server answers."
		}
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

	private var serverStatus: String {
		switch server.state {
		case .unconfigured: "Settings has no process-compose binary and config to start"
		case .remote: "Settings points at \(host), so the app cannot start a server there"

		case .idle: "No server started"
		case .running(let owned): owned ? "Running the server this app started" : "Attached to a server started elsewhere"
		case .failed(let reason): reason
		}
	}

	private var launchPlan: ServerLaunchPlan? {
		address.flatMap {
			ServerLaunchPlan(
				executablePath: binaryPath,
				configurationPath: configPath,
				workingDirectoryPath: workingDirectory,
				address: $0
			)
		}
	}

	private var mcpHelp: String {
		guard let url = mcpModel.url else { return "Settings has no usable MCP port" }
		return mcpModel.isReachable
			? "MCP server answering at \(url.absoluteString)"
			: "No MCP server at \(url.absoluteString)"
	}

	@ViewBuilder
	private var powerControl: some View {
		if power.isWorking {
			ProgressView()
				.controlSize(.small)
				.accessibilityLabel("Working on the stack")
		} else {
			Button(power.title, systemImage: "power") { power.perform() }
			.labelStyle(.titleAndIcon)
			.disabled(!power.isEnabled)
			.help(power.stops ? "Stop every running process" : "Start every process the stack defines")
		}
	}

	private var power: PowerAction {
		PowerAction(model: model, server: server)
	}

	@ViewBuilder
	private var content: some View {
		if model.isShowingDefinition {
			processList
				.safeAreaInset(edge: .top, spacing: 0) { stoppedBanner }
		} else if case .disconnected(let reason) = model.connection {
			ContentUnavailableView {
				Label("No stack running", systemImage: "bolt.horizontal.circle")
			} description: {
				Text(reason)
				Text(serverAdvice)
					.font(.callout)
				if let problem = model.definitionProblem {
					Text(problem)
						.font(.callout)
				}
			} actions: {
				offlineAction
			}
		} else if model.processes.isEmpty {
			ProgressView("Connecting")
				.frame(maxWidth: .infinity, maxHeight: .infinity)
		} else {
			processList
		}
	}

	private var processList: some View {
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

	private var stoppedBanner: some View {
		HStack(spacing: 12) {
			VStack(alignment: .leading, spacing: 2) {
				Text("The stack is not running")
					.font(.headline)
				Text(serverAdvice)
					.font(.callout)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}

			Spacer(minLength: 12)

			offlineAction
		}
		.noticeStyle()
		.accessibilityElement(children: .contain)
	}

	@ViewBuilder
	private var offlineAction: some View {
		if server.state == .unconfigured {
			Button("Set Up Server…") { windowState.isSettingUpServer = true }
		} else {
			Button(power.title) { power.perform() }
				.disabled(!power.isEnabled)
		}
	}

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
			canStart: model.canStart(name),
			canStop: model.canStop(name),
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

	/// Namespace and role, each shown only where it changes. The sidebar names the
	/// project, so the list does not repeat it.
	private func sectionHeader(for section: StackSection) -> some View {
		// A pinned header only reserves the height of its content, so the breathing room
		// goes on the labels themselves. Padding the container makes it cover the first row.
		VStack(alignment: .leading, spacing: 6) {
			if section.isFirstInNamespace {
				Text(section.namespace)
					.font(.title3.weight(.semibold))
					.foregroundStyle(.secondary)
					.padding(.top, 14)
			}
			if section.showsKind {
				Text(section.kind.label)
					.font(.body.weight(.medium))
					.foregroundStyle(.tertiary)
					.padding(.top, section.isFirstInNamespace ? 0 : 14)
					.padding(.leading, 10)
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
			}
			.noticeStyle()
			.transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
		}
	}

	/// Quitting waits on the stack, and this says so for as long as it takes. It also stands
	/// over the window, so nothing in it can be pressed meanwhile.
	private var stoppingOverlay: some View {
		VStack(spacing: 10) {
			ProgressView()
				.controlSize(.large)

			Text("Stopping the stack…")
				.font(.title3.weight(.semibold))

			Text("The app quits once everything has stopped.")
				.font(.callout)
				.foregroundStyle(.secondary)

			if !quit.stoppingProcesses.isEmpty {
				Text("Running when the stop began: \(quit.stoppingProcesses.joined(separator: ", "))")
					.font(.callout)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}
		}
		.padding(28)
		.frame(maxWidth: 440)
		.modifier(Panel(cornerRadius: 12))
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1 : 0.6))
		.contentShape(Rectangle())
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(.isModal)
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

	private var subtitle: String {
		guard let project = model.project else { return "Not connected" }
		return "\(model.runningCount) of \(model.processCount) running  ·  \(project.version)"
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

	private struct ServerInputs: Equatable {
		let address: ServerAddress?
		let plan: ServerLaunchPlan?
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
		model.use(client, at: address)
		logModel.use(client)
	}
}

/// What the window floats over its content. Material turns opaque when transparency is reduced.
private struct Panel: ViewModifier {
	var cornerRadius: CGFloat = 8

	@Environment(\.accessibilityReduceTransparency) private var reduceTransparency

	func body(content: Content) -> some View {
		content
			.background(background, in: RoundedRectangle(cornerRadius: cornerRadius))
			.overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(.separator))
	}

	private var background: AnyShapeStyle {
		reduceTransparency
			? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
			: AnyShapeStyle(.regularMaterial)
	}
}

private extension View {
	func noticeStyle() -> some View {
		padding(.horizontal, 12)
			.padding(.vertical, 8)
			.modifier(Panel())
			.padding(12)
	}
}

/// The toolbar readouts carry their state in the mark's shape as well as its color.
enum StatusSignal {
	case on
	case off
	case failed
}

// A toolbar Menu renders only its label's Text and Image, so the mark has to be a symbol.
struct StatusMark: View {
	let signal: StatusSignal
	let color: Color

	var body: some View {
		Image(systemName: symbol)
			.imageScale(.small)
			.symbolRenderingMode(.palette)
			.foregroundStyle(color)
	}

	private var symbol: String {
		switch signal {
		case .on: "circle.fill"
		case .off: "circle"
		case .failed: "exclamationmark.triangle.fill"
		}
	}
}
