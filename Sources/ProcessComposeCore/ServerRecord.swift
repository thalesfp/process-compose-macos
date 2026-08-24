import Darwin
import Foundation

/// The server the app started, kept on disk so a crash does not leave one running that
/// nothing owns. `owner` is the app that started it, so a second copy of the app can tell
/// a server it may take over from one another copy is still running.
/// Which app started a server. A pid alone is recycled, so the moment the process began
/// goes with it: together they name one run of one app and nothing else.
public struct ServerOwner: Codable, Sendable, Hashable {
	public let pid: Int32
	public let startedAt: Int64

	public init(pid: Int32, startedAt: Int64) {
		self.pid = pid
		self.startedAt = startedAt
	}

	public static var current: ServerOwner {
		let pid = ProcessInfo.processInfo.processIdentifier

		return ServerOwner(pid: pid, startedAt: UnixProcess.startedAt(pid) ?? 0)
	}

	/// Whether this is still the running process it was written for. An identity that could
	/// not be read is no identity: it never matches, so nothing is signalled on its word.
	public var isRunning: Bool {
		guard startedAt != 0, let now = UnixProcess.startedAt(pid) else { return false }

		return now == startedAt
	}
}

public struct ServerRecord: Codable, Sendable, Hashable {
	/// The group the server leads, not one process in it. The configured binary can be a
	/// script that starts process-compose and exits, and then no single pid outlives the
	/// stack.
	public let group: Int32
	public let port: Int
	public let owner: ServerOwner
	/// The processes each group was seen holding, keyed by group number. A number is handed
	/// out again once its group is gone, so it is no proof on its own; and a process that is
	/// still alive proves nothing about a group it has since left.
	public let members: [String: Set<ServerOwner>]

	public init(group: Int32, port: Int, owner: ServerOwner, members: [Int32: Set<ServerOwner>] = [:]) {
		self.group = group
		self.port = port
		self.owner = owner
		self.members = Dictionary(uniqueKeysWithValues: members.map { (String($0.key), $0.value) })
	}

	/// The recorded membership, keyed the way the process table reports it.
	public var membership: [Int32: Set<ServerOwner>] {
		Dictionary(uniqueKeysWithValues: members.compactMap { key, value in
			Int32(key).map { ($0, value) }
		})
	}
}

public protocol ServerRecordStore: Sendable {
	/// Records are kept per port: a copy of the app running a stack on one port must not
	/// lose its record because another copy started one on a different port.
	func load(port: Int) -> ServerRecord?
	func save(_ record: ServerRecord) throws
	func clear(_ record: ServerRecord) throws
	/// Held from the last look at the port until the record is written, so two copies of the
	/// app cannot both find the port free and both start a server on it.
	func claimLaunch(port: Int) -> ServerLaunchClaim?
}

/// A claim on starting a server, released when it is let go of.
public final class ServerLaunchClaim: Sendable {
	private let gate: Int32

	init?(path: String) {
		// Closed on exec, or the stack this claim is taken to start would inherit it and go
		// on holding the lock after the app that took it has gone.
		let gate = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)

		guard gate >= 0 else { return nil }

		// Never blocking: this can be reached from the main actor while another task of this
		// same process holds the claim across an await, and a wait would be a wait on itself.
		guard flock(gate, LOCK_EX | LOCK_NB) == 0 else {
			close(gate)
			return nil
		}

		self.gate = gate
	}

	deinit {
		flock(gate, LOCK_UN)
		close(gate)
	}
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

	public enum Fault: Error, LocalizedError {
		case unreadable

		public var errorDescription: String? {
			"The file recording the servers could not be read"
		}
	}

	public func load(port: Int) -> ServerRecord? {
		(try? all())?[String(port)]
	}

	/// Throws rather than starting again from nothing: the file holds the records of every
	/// port, and writing over one that cannot be read would lose the stacks named in it.
	private func all() throws -> [String: ServerRecord] {
		guard let data = try? Data(contentsOf: url) else { return [:] }

		do {
			return try JSONDecoder().decode([String: ServerRecord].self, from: data)
		} catch {
			throw Fault.unreadable
		}
	}

	public func save(_ record: ServerRecord) throws {
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)

		try holdingTheLock {
			var records = try all()
			records[String(record.port)] = record

			try JSONEncoder().encode(records).write(to: url, options: .atomic)
		}
	}

	/// Clears the record only when it still describes the given server, so a copy of the app
	/// that lost the race for the port does not delete the winner's. Reading, comparing and
	/// removing happen under one lock, or another copy could save between them.
	public func clear(_ record: ServerRecord) throws {
		try holdingTheLock {
			var records = try all()

			guard records[String(record.port)] == record else { return }

			records[String(record.port)] = nil

			if records.isEmpty {
				try FileManager.default.removeItem(at: url)
			} else {
				try JSONEncoder().encode(records).write(to: url, options: .atomic)
			}
		}
	}

	public func claimLaunch(port: Int) -> ServerLaunchClaim? {
		try? FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)

		return ServerLaunchClaim(path: url.appendingPathExtension("launch-\(port)").path)
	}

	// Copies of the app are separate processes, so the exclusion has to be one the system
	// holds: flock on a file beside the record.
	private func holdingTheLock(_ body: () throws -> Void) throws {
		let gate = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)

		guard gate >= 0 else { return try body() }

		defer { close(gate) }

		flock(gate, LOCK_EX)
		defer { flock(gate, LOCK_UN) }

		try body()
	}
}
