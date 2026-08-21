import Darwin
import Foundation

/// A process-compose server the app can signal: either one it started or one a previous
/// run left behind.
@MainActor
public protocol ServerProcess: AnyObject {
	var pid: Int32 { get }
	var isRunning: Bool { get }
	/// The server's own output, one line per element, finished when the server exits.
	var output: AsyncStream<String> { get }
	func exitCode() async -> Int32
	func terminate()
	func kill()
}

public enum ServerValidation: Sendable, Equatable {
	case valid
	case failed(reason: String)
}

@MainActor
public protocol ServerRunner {
	func run(_ plan: ServerLaunchPlan) throws -> any ServerProcess
	/// Loads the config without running it, so a stack that cannot start says why first.
	func validate(_ plan: ServerLaunchPlan) async -> ServerValidation
	/// Takes back a server recorded by an earlier run, or nil when that pid is gone or
	/// belongs to something else now.
	func adopt(pid: Int32) -> (any ServerProcess)?
}

public struct LiveServerRunner: ServerRunner {
	public init() {}

	public func run(_ plan: ServerLaunchPlan) throws -> any ServerProcess {
		try SpawnedServerProcess(plan)
	}

	public func validate(_ plan: ServerLaunchPlan) async -> ServerValidation {
		let process = Process()
		let pipe = Pipe()

		process.executableURL = plan.executable
		process.arguments = plan.validationArguments
		process.currentDirectoryURL = plan.workingDirectory
		process.environment = plan.environment(ProcessInfo.processInfo.environment)
		process.standardOutput = pipe
		process.standardError = pipe

		do {
			try process.run()
		} catch {
			return .failed(reason: error.localizedDescription)
		}

		let output = await Task.detached {
			let data = pipe.fileHandleForReading.readDataToEndOfFile()
			process.waitUntilExit()
			return (String(decoding: data, as: UTF8.self), process.terminationStatus)
		}.value

		guard output.1 != 0 else { return .valid }

		return .failed(reason: ServerValidation.reason(in: output.0))
	}

	public func adopt(pid: Int32) -> (any ServerProcess)? {
		// A pid is reused once the process behind it exits, so the name at that pid decides
		// whether this is still the server the app started.
		guard UnixProcess.isAlive(pid), UnixProcess.name(of: pid) == "process-compose" else { return nil }

		return AdoptedServerProcess(pid: pid)
	}
}

@MainActor
final class SpawnedServerProcess: ServerProcess {
	let output: AsyncStream<String>

	private let process = Process()
	private let exits: AsyncStream<Int32>

	var pid: Int32 { process.processIdentifier }
	var isRunning: Bool { process.isRunning }

	init(_ plan: ServerLaunchPlan) throws {
		let pipe = Pipe()
		let (lines, lineFeed) = AsyncStream<String>.makeStream()
		let (codes, codeFeed) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))

		output = lines
		exits = codes

		process.executableURL = plan.executable
		process.arguments = plan.arguments
		process.currentDirectoryURL = plan.workingDirectory
		process.environment = plan.environment(ProcessInfo.processInfo.environment)
		process.standardOutput = pipe
		process.standardError = pipe

		let buffer = LineBuffer()
		pipe.fileHandleForReading.readabilityHandler = { handle in
			let data = handle.availableData

			// An empty read is the pipe's end of file, and the handler keeps firing until
			// it is cleared.
			guard !data.isEmpty else {
				handle.readabilityHandler = nil
				lineFeed.finish()
				return
			}

			for line in buffer.take(data) { lineFeed.yield(line) }
		}

		process.terminationHandler = { finished in
			codeFeed.yield(finished.terminationStatus)
			codeFeed.finish()
		}

		try process.run()
	}

	func exitCode() async -> Int32 {
		for await code in exits { return code }
		return 0
	}

	func terminate() {
		guard process.isRunning else { return }
		process.terminate()
	}

	func kill() {
		guard process.isRunning else { return }
		Darwin.kill(process.processIdentifier, SIGKILL)
	}
}

@MainActor
final class AdoptedServerProcess: ServerProcess {
	let pid: Int32

	// The output of a server this app did not spawn went to the terminal that did.
	let output = AsyncStream<String> { $0.finish() }

	var isRunning: Bool { UnixProcess.isAlive(pid) }

	init(pid: Int32) {
		self.pid = pid
	}

	/// A process this one never forked reports no status to it, so the exit is only visible
	/// as the pid going away.
	func exitCode() async -> Int32 {
		while isRunning {
			do {
				try await Task.sleep(for: .seconds(1), tolerance: .seconds(1))
			} catch {
				return 0
			}
		}
		return 0
	}

	func terminate() {
		Darwin.kill(pid, SIGTERM)
	}

	func kill() {
		Darwin.kill(pid, SIGKILL)
	}
}

extension ServerValidation {
	/// process-compose reports the fault as its last log line, coloured and prefixed with
	/// the level and a timestamp.
	static func reason(in output: String) -> String {
		let lines = output
			.split(whereSeparator: \.isNewline)
			.map { LogLine(id: 0, spans: AnsiParser.spans(in: String($0))).text }
			.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

		guard let last = lines.last else { return "The config would not load" }

		return last.trimmingCharacters(in: .whitespaces)
	}
}

enum UnixProcess {
	static func isAlive(_ pid: Int32) -> Bool {
		guard pid > 0 else { return false }
		// A process owned by another user answers EPERM, which still means it is there.
		return Darwin.kill(pid, 0) == 0 || errno == EPERM
	}

	static func name(of pid: Int32) -> String? {
		var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
		let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))

		guard length > 0 else { return nil }

		let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)

		return URL(fileURLWithPath: path).lastPathComponent
	}
}

/// Reassembles lines from pipe reads, which land on a background queue and split wherever
/// the buffer happened to fill.
private final class LineBuffer: @unchecked Sendable {
	private var pending = Data()
	private let lock = NSLock()

	func take(_ data: Data) -> [String] {
		lock.lock()
		defer { lock.unlock() }

		pending.append(data)

		var lines: [String] = []
		var start = pending.startIndex
		while let newline = pending[start...].firstIndex(of: 0x0A) {
			lines.append(String(decoding: pending[start ..< newline], as: UTF8.self))
			start = pending.index(after: newline)
		}
		pending.removeSubrange(pending.startIndex ..< start)

		return lines
	}
}
