import Foundation

/// The server the app started, kept on disk so a crash does not leave one running that
/// nothing owns. `owner` is the app that started it, so a second copy of the app can tell
/// a server it may take over from one another copy is still running.
public struct ServerRecord: Codable, Sendable, Hashable {
	public let pid: Int32
	public let port: Int
	public let owner: Int32

	public init(pid: Int32, port: Int, owner: Int32) {
		self.pid = pid
		self.port = port
		self.owner = owner
	}
}

public protocol ServerRecordStore: Sendable {
	func load() -> ServerRecord?
	func save(_ record: ServerRecord) throws
	func clear() throws
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
		try JSONEncoder().encode(record).write(to: url, options: .atomic)
	}

	public func clear() throws {
		guard FileManager.default.fileExists(atPath: url.path) else { return }

		try FileManager.default.removeItem(at: url)
	}
}
