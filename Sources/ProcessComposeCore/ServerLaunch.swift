import Foundation

/// Everything needed to run `process-compose up`, resolved before anything is spawned.
public struct ServerLaunchPlan: Sendable, Hashable {
	public let executable: URL
	public let configuration: URL
	public let workingDirectory: URL
	public let host: String
	public let port: Int

	/// A config's `working_dir` and `watch` paths resolve against the directory
	/// process-compose runs in, which is not always the one holding the config.
	public init?(
		executablePath: String,
		configurationPath: String,
		workingDirectoryPath: String = "",
		host: String = ServerAddress.defaultHost,
		port: Int
	) {
		let executable = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
		let configuration = configurationPath.trimmingCharacters(in: .whitespacesAndNewlines)
		let workingDirectory = workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)

		guard !executable.isEmpty, !configuration.isEmpty, (1 ... 65535).contains(port) else { return nil }

		self.executable = Self.url(executable)
		self.configuration = Self.url(configuration)
		self.workingDirectory = workingDirectory.isEmpty
			? Self.url(configuration).deletingLastPathComponent()
			: URL(fileURLWithPath: (workingDirectory as NSString).expandingTildeInPath, isDirectory: true)
		self.host = host
		self.port = port
	}

	private static func url(_ path: String) -> URL {
		URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: false)
	}

	/// `--detached` forks and returns, while `-t=false` keeps a live child to signal. The
	/// address is named rather than left to `PC_ADDRESS`, which the environment can set to
	/// one that answers the whole network.
	public var arguments: [String] {
		[
			"up", "-f", configuration.path,
			"--address", host, "-p", "\(port)",
			"-t=false", "--keep-project",
		]
	}

	/// Loads the config, reports what is wrong with it, and exits without running anything.
	public var validationArguments: [String] {
		["up", "--dry-run", "-f", configuration.path]
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
	/// can be started from the app the next time. A config already set is left alone, and a
	/// server built from several configs is left to the user, since one of them starts a
	/// part of the stack.
	public static func learnedConfiguration(from configFiles: [String], current: String) -> String? {
		guard current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

		// process-compose reports the env files it loaded alongside the configs.
		let configs = configFiles.filter { ["yaml", "yml"].contains(URL(fileURLWithPath: $0).pathExtension) }

		return configs.count == 1 ? configs.first : nil
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
