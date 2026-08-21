import AppKit
import ProcessComposeCore
import SwiftUI

@main
struct ProcessComposeApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

	private static let client = LiveProcessComposeClient(address: .fromEnvironment())
	@MainActor fileprivate static let server = ServerSupervisor()

	@State private var model = StackViewModel(client: client)
	@State private var logModel = LogViewModel(client: client)
	@State private var mcpModel = MCPServerViewModel()
	@State private var server = ProcessComposeApp.server

	@AppStorage(PreferenceKey.logFontSize) private var logFontSize = LogFont.standard

	var body: some Scene {
		WindowGroup {
			StackView(model: model, logModel: logModel, mcpModel: mcpModel, server: server)
				.frame(minWidth: 900, minHeight: 480)
		}
		.defaultSize(width: 1160, height: 760)
		.windowToolbarStyle(.unified)
		.commands {
			StackCommands(model: model, logModel: logModel, logFontSize: $logFontSize)
		}

		Settings {
			SettingsView()
		}
	}
}

// A SwiftPM executable launches as an accessory process, so the window would open
// behind every other app and take no menu bar without an explicit activation policy.
final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApplication.shared.setActivationPolicy(.regular)
		NSApplication.shared.activate(ignoringOtherApps: true)
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
	}

	func applicationWillTerminate(_ notification: Notification) {
		ProcessComposeApp.server.stopOnQuit()
	}
}
