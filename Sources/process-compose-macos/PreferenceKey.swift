import ProcessComposeCore
import Foundation

/// The UserDefaults keys the Settings window and the views share.
enum PreferenceKey {
	static let host = "serverHost"
	static let port = "serverPort"
	static let mcpPort = "mcpServerPort"
	static let logFontSize = "logFontSize"
	static let logBufferLines = "logBufferLines"
	static let logBackfill = "logBackfill"
	static let splitFraction = "splitFraction"
	static let selectedProject = "selectedProject"
	static let serverBinaryPath = "serverBinaryPath"
	static let serverConfigPath = "serverConfigPath"
	/// What an attached server said its config was. Only a suggestion: the app runs the
	/// config the user saved, since whatever answers the port could name any file it likes.
	static let suggestedConfigPath = "suggestedConfigPath"
	static let serverWorkingDirectory = "serverWorkingDirectory"
	static let sidebarVisible = "sidebarVisible"
}

enum PreferenceDefault {
	static let host = "localhost"
	static let port = ServerAddress.fromEnvironment().port
	static let mcpPort = ServerAddress.defaultMCPPort
	static let logBufferLines = 2000
	static let logBackfill = 300
	static let splitFraction = 0.6
	static let serverBinaryPath = ServerBinary.discover() ?? ""
	static let serverConfigPath = ""
	static let serverWorkingDirectory = ""
	static let suggestedConfigPath = ""
}
