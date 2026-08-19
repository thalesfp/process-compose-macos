import ConductorCore
import SwiftUI

/// The menu bar. Every action the window offers is reachable from here with a key.
struct StackCommands: Commands {
	@Bindable var model: StackViewModel
	@Bindable var logModel: LogViewModel
	@Binding var logFontSize: Double

	var body: some Commands {
		CommandGroup(replacing: .newItem) {}

		CommandGroup(after: .toolbar) {
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
		}

		CommandMenu("Process") {
			Button(title("Start")) { run(model.startProcess) }
				.keyboardShortcut("r", modifiers: .command)
				.disabled(!canStart)

			Button(title("Restart")) { run(model.restartProcess) }
				.keyboardShortcut("r", modifiers: [.command, .shift])
				.disabled(!canStop)

			Button(title("Stop")) { run(model.stopProcess) }
				.keyboardShortcut(".", modifiers: .command)
				.disabled(!canStop)

			Divider()

			Button("Copy Name") { copySelectedName() }
				.keyboardShortcut("c", modifiers: [.command, .shift])
				.disabled(model.selection == nil)

			Divider()

			Button(model.power == .canStop ? "Stop Stack..." : "Start Stack") {
				if model.power == .canStop {
					model.isConfirmingStopStack = true
				} else {
					Task { await model.startStack() }
				}
			}
			.keyboardShortcut(".", modifiers: [.command, .control])
			.disabled(model.connection != .connected || model.power == .unavailable || model.isChangingStack)
		}

		CommandMenu("Log") {
			Toggle("Follow", isOn: $logModel.isFollowing)
				.keyboardShortcut("f", modifiers: [.command, .shift])

			Button("Clear Log") { Task { await logModel.clear() } }
				.keyboardShortcut("k", modifiers: .command)
				.disabled(logModel.selected == nil)
		}
	}

	private var canStart: Bool {
		model.selectedProcess?.canStart == true && !model.isBusy(model.selection)
	}

	private var canStop: Bool {
		model.selectedProcess?.canStop == true && !model.isBusy(model.selection)
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
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(name, forType: .string)
	}
}
