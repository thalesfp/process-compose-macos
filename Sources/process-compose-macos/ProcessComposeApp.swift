import AppKit
import ProcessComposeCore
import SwiftUI

@main
struct ProcessComposeApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

	private static let client = LiveProcessComposeClient(address: .fromEnvironment())

	@State private var model = StackViewModel(client: client)
	@State private var logModel = LogViewModel(client: client)
	@State private var mcpModel = MCPServerViewModel()

	@AppStorage(PreferenceKey.logFontSize) private var logFontSize = LogFont.standard

	var body: some Scene {
		WindowGroup {
			StackView(model: model, logModel: logModel, mcpModel: mcpModel)
				.frame(minWidth: 760, minHeight: 480)
		}
		.defaultSize(width: 980, height: 760)
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
}
