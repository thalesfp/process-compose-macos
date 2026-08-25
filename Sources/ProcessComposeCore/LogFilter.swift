import Foundation

public enum LogFilter {
	/// Narrows a buffer to the lines holding a substring. Matching ignores case, so a
	/// filter typed in lower case still finds a log level the process shouted.
	public static func matching(_ lines: [LogLine], filter: String) -> [LogLine] {
		guard !filter.isEmpty else { return lines }

		return lines.filter { $0.text.localizedCaseInsensitiveContains(filter) }
	}

	/// How a pane says what it is showing: the whole buffer, or the part a filter kept.
	public static func countLabel(visible: Int, total: Int, filter: String) -> String {
		filter.isEmpty ? "\(total) lines" : "\(visible) of \(total) lines"
	}
}
