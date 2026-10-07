import AppKit
import ProcessComposeCore
import SwiftUI

@main
struct ProcessComposeApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

	private static let client = LiveProcessComposeClient(address: .fromEnvironment())
	@MainActor fileprivate static let server = ServerSupervisor()
	@MainActor fileprivate static let model = StackViewModel(client: client)

	@State private var model = ProcessComposeApp.model
	@State private var logModel = LogViewModel(client: client)
	@State private var mcpModel = MCPServerViewModel()
	@State private var server = ProcessComposeApp.server

	@AppStorage(PreferenceKey.logFontSize) private var logFontSize = LogFont.standard

	var body: some Scene {
		Window("Process Compose", id: "main") {
			StackView(
				model: model,
				logModel: logModel,
				mcpModel: mcpModel,
				server: server
			)
			.frame(minWidth: 1040, minHeight: 480)
		}
		.defaultSize(width: 1160, height: 760)
		.windowToolbarStyle(.unified)
		.commands {
			StackCommands(
				model: model,
				logModel: logModel,
				server: server,
				logFontSize: $logFontSize
			)
		}

		Settings {
			SettingsView(server: server)
		}
	}
}

// A SwiftPM executable launches as an accessory process, so the window would open
// behind every other app and take no menu bar without an explicit activation policy.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	private var alerts: FailureAlerts?

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApplication.shared.setActivationPolicy(.regular)
		NSApplication.shared.activate(ignoringOtherApps: true)

		alerts = FailureAlerts(model: ProcessComposeApp.model)
	}

	func applicationDidBecomeActive(_ notification: Notification) {
		alerts?.acknowledge()
	}

	func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
		let menu = NSMenu()
		menu.autoenablesItems = false

		let item = NSMenuItem(title: power.title, action: #selector(togglePower), keyEquivalent: "")
		item.target = self
		item.isEnabled = power.isEnabled
		menu.addItem(item)

		return menu
	}

	/// Stopping asks in the window, so the window comes forward with the question.
	@objc private func togglePower() {
		NSApp.activate()
		power.perform()
	}

	private var power: PowerAction {
		PowerAction(model: ProcessComposeApp.model, server: ProcessComposeApp.server)
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
	}

	/// The stack goes down with the app, which is worth asking about first.
	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		guard ProcessComposeApp.server.isOwned else { return .terminateNow }

		let alert = NSAlert()
		alert.messageText = "Stop the stack before quitting?"
		alert.informativeText = "The app started this server. Quitting stops it and every process it is running."
		alert.addButton(withTitle: "Stop and Quit")
		alert.addButton(withTitle: "Cancel")

		guard let window = sender.mainWindow ?? sender.windows.first(where: \.isVisible) else {
			guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

			Task { @MainActor in
				await ProcessComposeApp.server.stop()
				sender.reply(toApplicationShouldTerminate: true)
			}

			return .terminateLater
		}

		// A sheet drops from the window the stack belongs to, so the question arrives where
		// the user was looking. It answers later, which is what `terminateLater` waits for.
		alert.beginSheetModal(for: window) { response in
			guard response == .alertFirstButtonReturn else {
				sender.reply(toApplicationShouldTerminate: false)
				return
			}

			// Stopping is awaited rather than waited out in place, so process-compose gets
			// its full shutdown without the app freezing while it takes it.
			Task { @MainActor in
				await ProcessComposeApp.server.stop()
				sender.reply(toApplicationShouldTerminate: true)
			}
		}

		return .terminateLater
	}

	// A quit the delegate never sees, such as a log out, still has to take the server with it.
	func applicationWillTerminate(_ notification: Notification) {
		ProcessComposeApp.server.stopOnQuit()
		LiveServerRunner.endRunningChecks()
	}
}
