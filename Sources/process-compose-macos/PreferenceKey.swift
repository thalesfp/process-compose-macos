import ProcessComposeCore
import Foundation

/// The UserDefaults keys the Settings window and the views share.
enum PreferenceKey {
	static let host = "serverHost"
	static let port = "serverPort"
	static let logFontSize = "logFontSize"
	static let logBufferLines = "logBufferLines"
	static let logBackfill = "logBackfill"
	static let splitFraction = "splitFraction"
}

enum PreferenceDefault {
	static let host = "localhost"
	static let port = ServerAddress.fromEnvironment().port
	static let logBufferLines = 2000
	static let logBackfill = 300
	static let splitFraction = 0.6
}
