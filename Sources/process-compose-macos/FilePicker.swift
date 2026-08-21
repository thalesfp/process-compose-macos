import AppKit

/// The open panel the Settings fields and the empty state share.
enum FilePicker {
	static func choose(_ message: String, isDirectory: Bool = false, startingAt path: String = "") -> String? {
		let panel = NSOpenPanel()
		panel.canChooseFiles = !isDirectory
		panel.canChooseDirectories = isDirectory
		panel.allowsMultipleSelection = false
		panel.prompt = "Choose"
		panel.message = message
		if !path.isEmpty {
			panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
		}

		guard panel.runModal() == .OK, let url = panel.url else { return nil }

		return url.path
	}
}
