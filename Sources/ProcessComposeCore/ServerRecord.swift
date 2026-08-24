import Darwin
import Foundation

/// The server the app started, kept on disk so a crash does not leave one running that
/// nothing owns. `owner` is the app that started it, so a second copy of the app can tell
/// a server it may take over from one another copy is still running.
public struct ServerRecord: Codable, Sendable, Hashable {
	/// The group the server leads, not one process in it. The configured binary can be a
	/// script that starts process-compose and exits, and then no single pid outlives the
	/// stack.
	public let group: Int32
	public let port: Int
	public let owner: Int32

	public init(group: Int32, port: Int, owner: Int32) {
		self.group = group
		self.port = port
		self.owner = owner
	}
}

public protocol ServerRecordStore: Sendable {
	func load() -> ServerRecord?
	func save(_ record: ServerRecord) throws
	func clear(_ record: ServerRecord) throws
}

public struct FileServerRecordStore: ServerRecordStore {
	private let url: URL

	public init(url: URL = FileServerRecordStore.defaultURL) {
		self.url = url
	}

	public static var defaultURL: URL {
		let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

		return support
			.appendingPathComponent("me.thales.process-compose", isDirectory: true)
			.appendingPathComponent("server.json")
	}

	public func load() -> ServerRecord? {
		guard let data = try? Data(contentsOf: url) else { return nil }

		return try? JSONDecoder().decode(ServerRecord.self, from: data)
	}

	public func save(_ record: ServerRecord) throws {
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)

		try holdingTheLock {
			try JSONEncoder().encode(record).write(to: url, options: .atomic)
		}
	}

	/// Clears the record only when it still describes the given server, so a copy of the app
	/// that lost the race for the port does not delete the winner's. Reading, comparing and
	/// removing happen under one lock, or another copy could save between them.
	public func clear(_ record: ServerRecord) throws {
		try holdingTheLock {
			guard load() == record else { return }

			try FileManager.default.removeItem(at: url)
		}
	}

	// Copies of the app are separate processes, so the exclusion has to be one the system
	// holds: flock on a file beside the record.
	private func holdingTheLock(_ body: () throws -> Void) throws {
		let gate = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o644)

		guard gate >= 0 else { return try body() }

		defer { close(gate) }

		flock(gate, LOCK_EX)
		defer { flock(gate, LOCK_UN) }

		try body()
	}
}
