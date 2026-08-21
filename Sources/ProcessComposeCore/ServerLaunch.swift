import Foundation

/// Everything needed to run `process-compose up`, resolved before anything is spawned.
public struct ServerLaunchPlan: Sendable, Hashable {
	public let executable: URL
	public let configuration: URL
	public let port: Int

	public init?(executablePath: String, configurationPath: String, port: Int) {
		let executable = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
		let configuration = configurationPath.trimmingCharacters(in: .whitespacesAndNewlines)

		guard !executable.isEmpty, !configuration.isEmpty, (1 ... 65535).contains(port) else { return nil }

		self.executable = URL(fileURLWithPath: (executable as NSString).expandingTildeInPath, isDirectory: false)
		self.configuration = URL(fileURLWithPath: (configuration as NSString).expandingTildeInPath, isDirectory: false)
		self.port = port
	}

	/// Paths inside a process-compose config resolve against the config file's directory.
	public var workingDirectory: URL {
		configuration.deletingLastPathComponent()
	}

	/// `--detached` forks and returns, while `-t=false` keeps a live child to signal.
	public var arguments: [String] {
		["up", "-f", configuration.path, "-p", "\(port)", "-t=false", "--keep-project"]
	}

	/// An app opened from Finder inherits `PATH=/usr/bin:/bin:/usr/sbin:/sbin`.
	public func environment(_ base: [String: String]) -> [String: String] {
		var environment = base
		let existing = base["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
		var added: [String] = []

		for candidate in [executable.deletingLastPathComponent().path] + Self.toolPaths
		where !existing.contains(candidate) && !added.contains(candidate) {
			added.append(candidate)
		}

		environment["PATH"] = (added + existing).joined(separator: ":")

		return environment
	}

	/// The config of the server the app is attached to, so a stack started from a terminal
	/// can be started from the app the next time. A config already set is left alone.
	public static func learnedConfiguration(from configFiles: [String], current: String) -> String? {
		guard current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

		return configFiles.first { !$0.isEmpty }
	}

	static var toolPaths: [String] {
		["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
	}
}

/// Where process-compose lands when installed by Homebrew, by `go install`, or by hand.
public enum ServerBinary {
	static var searchPaths: [String] {
		[
			"/opt/homebrew/bin/process-compose",
			"/usr/local/bin/process-compose",
			NSHomeDirectory() + "/go/bin/process-compose",
		]
	}

	public static func discover(
		isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
	) -> String? {
		searchPaths.first(where: isExecutable)
	}
}
