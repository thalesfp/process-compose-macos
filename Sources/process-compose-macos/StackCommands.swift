import AppKit
import ProcessComposeCore
import SwiftUI

/// The menu bar. Every action the window offers is reachable from here, and the
/// process, stack and server tiers take Cmd, Cmd+Ctrl and Cmd+Option in turn.
struct StackCommands: Commands {
	@Bindable var model: StackViewModel
	@Bindable var logModel: LogViewModel
	let server: ServerSupervisor
	@Binding var logFontSize: Double

	@FocusedValue(\.windowState) private var windowState: WindowState?

	@AppStorage(PreferenceKey.sidebarVisible) private var isSidebarVisible = true
	@AppStorage(PreferenceKey.splitFraction) private var splitFraction = PreferenceDefault.splitFraction

	var body: some Commands {
		CommandGroup(replacing: .newItem) {}

		CommandGroup(after: .toolbar) {
			Button(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") { isSidebarVisible.toggle() }
				.keyboardShortcut("s", modifiers: [.command, .control])

			Divider()

			Button("Bigger Log Text") { logFontSize = LogFont.stepped(logFontSize, by: 1) }
				.keyboardShortcut(KeyEquivalent("="), modifiers: .command)
				.disabled(logFontSize >= LogFont.range.upperBound)

			Button("Smaller Log Text") { logFontSize = LogFont.stepped(logFontSize, by: -1) }
				.keyboardShortcut(KeyEquivalent("-"), modifiers: .command)
				.disabled(logFontSize <= LogFont.range.lowerBound)

			Button("Actual Size") { logFontSize = LogFont.standard }
				.keyboardShortcut(KeyEquivalent("0"), modifiers: .command)
				.disabled(logFontSize == LogFont.standard)

			Divider()

			Button("Taller Log Pane") { splitFraction = SplitLayout.stepped(splitFraction, by: -SplitLayout.step) }
				.keyboardShortcut(.downArrow, modifiers: [.command, .control])
				.disabled(splitFraction <= SplitLayout.fractionRange.lowerBound)

			Button("Shorter Log Pane") { splitFraction = SplitLayout.stepped(splitFraction, by: SplitLayout.step) }
				.keyboardShortcut(.upArrow, modifiers: [.command, .control])
				.disabled(splitFraction >= SplitLayout.fractionRange.upperBound)

			Button("Reset Split") { splitFraction = PreferenceDefault.splitFraction }
				.keyboardShortcut(KeyEquivalent("0"), modifiers: [.command, .control])
				.disabled(splitFraction == PreferenceDefault.splitFraction)

			Divider()
		}

		// One menu that widens as it is read: the selected process, then its project,
		// then every project the server is running.
		CommandMenu("Stack") {
			Button(title("Start")) { run(model.startProcess) }
				.keyboardShortcut("r", modifiers: .command)
				.disabled(!model.canStart(model.selection))

			Button(title("Restart")) { run(model.restartProcess) }
				.keyboardShortcut("r", modifiers: [.command, .shift])
				.disabled(!model.canStop(model.selection))

			Button(title("Stop")) { run(model.stopProcess) }
				.keyboardShortcut(".", modifiers: .command)
				.disabled(!model.canStop(model.selection))

			Divider()

			ProjectActions(model: model, project: model.selectedProject)

			Divider()

			Button("Copy Name") { copySelectedName() }
				.keyboardShortcut("c", modifiers: [.command, .shift])
				.disabled(model.selection == nil)

			Divider()

			Button(model.power == .canStop ? "Stop Stack..." : "Start Stack") { model.togglePower() }
				.keyboardShortcut(".", modifiers: [.command, .control])
				.disabled(!model.canChangePower)
		}

		CommandMenu("Server") {
			Button("Start Server") { Task { await server.start() } }
				.keyboardShortcut("r", modifiers: [.command, .option])
				.disabled(!server.canStart)

			Button("Stop Server...") { model.confirmTarget = .stopServer(identity: server.identity) }
				.keyboardShortcut(".", modifiers: [.command, .option])
				.disabled(!server.isOwned)

			Divider()

			Button("Set Up Server...") { windowState?.isSettingUpServer = true }
				.keyboardShortcut("s", modifiers: [.command, .option])
				.disabled(windowState == nil)

			Button("Show Server Log") { windowState?.isShowingServerLog = true }
				.keyboardShortcut("l", modifiers: [.command, .option])
				.disabled(windowState?.isShowingServerLog ?? true)

			Divider()

			Button("Show Config in Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.configURLs) }
				.disabled(model.configURLs.isEmpty)
		}

		CommandMenu("Log") {
			Button("Filter Log") { windowState?.filterFocusToken += 1 }
				.keyboardShortcut("f", modifiers: .command)
				.disabled(windowState == nil)

			Divider()

			Toggle("Follow", isOn: $logModel.isFollowing)
				.keyboardShortcut("f", modifiers: [.command, .shift])

			Button("Clear Log") { Task { await logModel.clear() } }
				.keyboardShortcut("k", modifiers: .command)
				.disabled(logModel.selected == nil)
		}
	}

	private func title(_ verb: String) -> String {
		model.selection.map { "\(verb) \($0)" } ?? verb
	}

	private func run(_ action: @escaping (String) async -> Void) {
		guard let name = model.selection else { return }
		Task { await action(name) }
	}

	private func copySelectedName() {
		guard let name = model.selection else { return }
		NSPasteboard.copy(name)
	}
}
