import AppKit

extension NSPasteboard {
	/// Both the row's context menu and the Process menu copy a process name this way.
	static func copy(_ text: String) {
		general.clearContents()
		general.setString(text, forType: .string)
	}
}
