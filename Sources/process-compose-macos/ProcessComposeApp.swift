import AppKit
import ProcessComposeCore
import SwiftUI

@main
struct ProcessComposeApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

	private static let client = LiveProcessComposeClient(address: .fromEnvironment())
	@MainActor fileprivate static let server = ServerSupervisor()
	@MainActor fileprivate static let model = StackViewModel(client: client)
	@MainActor fileprivate static let quit = QuitCoordinator(model: model, server: server)

	@State private var model = ProcessComposeApp.model
	@State private var logModel = LogViewModel(client: client)
	@State private var mcpModel = MCPServerViewModel()
	@State private var server = ProcessComposeApp.server
	@State private var quit = ProcessComposeApp.quit

	@AppStorage(PreferenceKey.logFontSize) private var logFontSize = LogFont.standard

	var body: some Scene {
		Window("Process Compose", id: "main") {
			StackView(
				model: model,
				logModel: logModel,
				mcpModel: mcpModel,
				server: server,
				quit: quit
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
				quit: quit,
				logFontSize: $logFontSize
			)
		}

		Settings {
			SettingsView(server: server, quit: quit)
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

		NSAppleEventManager.shared().setEventHandler(
			self,
			andSelector: #selector(handleQuit(_:withReply:)),
			forEventClass: AEEventClass(kCoreEventClass),
			andEventID: AEEventID(kAEQuitApplication)
		)
	}

	/// Stands in for AppKit's own quit handler, which a sheet on screen would stop short.
	@objc private func handleQuit(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
		ProcessComposeApp.quit.makeRoom(for: QuitReason(event: event))
		NSApp.terminate(nil)
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

	/// Every way of quitting arrives here, and the coordinator decides what each one needs.
	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		ProcessComposeApp.quit.shouldTerminate(.ofCurrentEvent)
	}

	// Leaving the stack running was chosen, or the system could not wait; anything else
	// still held at this point goes with the app.
	func applicationWillTerminate(_ notification: Notification) {
		if !ProcessComposeApp.quit.leavesStackRunning {
			ProcessComposeApp.server.stopOnQuit()
		}

		LiveServerRunner.endRunningChecks()
	}
}
