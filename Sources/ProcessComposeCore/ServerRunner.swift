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
	/// Takes back a server recorded by an earlier run, or nil when its group is gone or now
	/// holds processes none of `names` describes.
	func adopt(group: Int32, names: Set<String>) -> (any ServerProcess)?
	func isRunning(pid: Int32) -> Bool
}

public struct LiveServerRunner: ServerRunner {
	private let validationTimeout: Duration

	public init(validationTimeout: Duration = .seconds(30)) {
		self.validationTimeout = validationTimeout
	}

	public func run(_ plan: ServerLaunchPlan) throws -> any ServerProcess {
		try SpawnedServerProcess(plan)
	}

	public func validate(_ plan: ServerLaunchPlan) async -> ServerValidation {
		let check: GroupedProcess
		do {
			check = try GroupedProcess.run(
				executable: plan.executable,
				arguments: plan.validationArguments,
				workingDirectory: plan.workingDirectory,
				environment: plan.environment(ProcessInfo.processInfo.environment)
			)
		} catch {
			return .failed(reason: error.localizedDescription)
		}

		// The binary can be a script of the user's own, which can hang, wait on input that
		// never comes, or leave a child holding the pipe, so reading is raced against the
		// clock rather than trusted to finish.
		let reader = Task.detached {
			let printed = check.read()
			check.waitUntilExit()

			return printed
		}

		let printed = await withTaskCancellationHandler {
			await Self.first(of: reader, within: validationTimeout)
		} onCancel: {
			check.signal(SIGTERM)
		}

		guard let printed else {
			Task { await Self.end(check) }

			return .failed(reason: "The config check did not finish")
		}

		guard check.reap() != 0 else { return .valid }

		return .failed(reason: ServerValidation.reason(in: printed))
	}

	/// The reader's answer, or nothing once the wait is over. A task group would hold this
	/// until every child returned, and the child reading the pipe is the one that hangs.
	private static func first(
		of reader: Task<String, Never>,
		within timeout: Duration
	) async -> String? {
		let answer = FirstAnswer()

		return await withCheckedContinuation { continuation in
			Task {
				answer.deliver(await reader.value, to: continuation)
			}

			Task {
				try? await Task.sleep(for: timeout)
				answer.deliver(nil, to: continuation)
			}
		}
	}

	/// A script that ignores SIGTERM, and whatever it started, still has to go. The status
	/// is collected only once the last signal is out.
	private static func end(_ check: GroupedProcess) async {
		check.signal(SIGTERM)

		try? await Task.sleep(for: .seconds(1))

		check.signal(SIGKILL)
		check.reap()
	}

	public func isRunning(pid: Int32) -> Bool {
		UnixProcess.isAlive(pid)
	}

	public func adopt(group: Int32, names: Set<String>) -> (any ServerProcess)? {
		guard let existing = GroupedProcess.adopt(group: group, names: names) else { return nil }

		return AdoptedServerProcess(existing)
	}
}

@MainActor
final class SpawnedServerProcess: ServerProcess {
	let output: AsyncStream<String>

	private let check: GroupedProcess
	private let exits: AsyncStream<Int32>

	var pid: Int32 { check.pid }
	var isRunning: Bool { check.hasMembers }

	init(_ plan: ServerLaunchPlan) throws {
		// The binary can be a script that starts process-compose without replacing itself,
		// and then the stack is a grandchild. A group of its own is what makes it reachable.
		check = try GroupedProcess.run(
			executable: plan.executable,
			arguments: plan.arguments,
			workingDirectory: plan.workingDirectory,
			environment: plan.environment(ProcessInfo.processInfo.environment)
		)

		// A stack can print faster than the pane reads, and the log's own limit cannot hold
		// back a queue in front of it.
		let (lines, lineFeed) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(4096))
		let (codes, codeFeed) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))

		output = lines
		exits = codes

		let started = check
		Task.detached {
			let buffer = LineBuffer()
			started.drain { data in
				for line in buffer.take(data) { lineFeed.yield(line) }
			}
			lineFeed.finish()

			started.waitUntilExit()
			let status = started.reap()

			// The wrapper can go before what it started, and the stack is only over once
			// nothing in the group is left.
			while started.hasMembers { usleep(50_000) }

			codeFeed.yield(status)
			codeFeed.finish()
		}
	}

	func exitCode() async -> Int32 {
		for await code in exits { return code }
		return 0
	}

	func terminate() {
		check.signal(SIGTERM)
	}

	func kill() {
		check.signal(SIGKILL)
	}
}

@MainActor
final class AdoptedServerProcess: ServerProcess {
	// The output of a server this app did not spawn went to the terminal that did.
	let output = AsyncStream<String> { $0.finish() }

	private let group: GroupedProcess
	private let pollInterval: Duration

	var pid: Int32 { group.pid }
	var isRunning: Bool { group.hasMembers }

	init(_ group: GroupedProcess, pollInterval: Duration = .seconds(1)) {
		self.group = group
		self.pollInterval = pollInterval
	}

	/// A group this process never forked reports no status to it, so the end is only visible
	/// as the last member going away.
	func exitCode() async -> Int32 {
		while isRunning {
			do {
				try await Task.sleep(for: pollInterval, tolerance: pollInterval)
			} catch {
				return 0
			}
		}
		return 0
	}

	func terminate() {
		group.signal(SIGTERM)
	}

	func kill() {
		group.signal(SIGKILL)
	}
}

extension ServerValidation {
	/// process-compose reports the fault as its last log line: coloured, prefixed with a
	/// timestamp and a level, and carrying the detail in an `error="..."` field.
	static func reason(in output: String) -> String {
		let lines = output
			.split(whereSeparator: \.isNewline)
			.map { LogLine(id: 0, spans: AnsiParser.spans(in: String($0))).text }
			.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

		guard let last = lines.last else { return "The config would not load" }

		return message(in: last.trimmingCharacters(in: .whitespaces))
	}

	static func message(in line: String) -> String {
		var text = Substring(line)

		if let prefix = text.prefixMatch(of: /\d{2}-\d{2}-\d{2} [\d:.]+ [A-Z]{3}\s+/) {
			text = text[prefix.range.upperBound...]
		}

		guard let detail = text.firstMatch(of: /\s*error="(.+)"\s*$/) else { return String(text) }

		return text[..<detail.range.lowerBound] + ": " + detail.1
	}
}

/// Whichever of the reader and the clock answers first, once.
private final class FirstAnswer: @unchecked Sendable {
	private let lock = NSLock()
	private var delivered = false

	func deliver(
		_ value: String?,
		to continuation: CheckedContinuation<String?, Never>
	) {
		lock.lock()
		let isFirst = !delivered
		delivered = true
		lock.unlock()

		guard isFirst else { return }

		continuation.resume(returning: value)
	}
}

enum UnixProcess {
	static func isAlive(_ pid: Int32) -> Bool {
		guard pid > 0 else { return false }
		// A process owned by another user answers EPERM, which still means it is there.
		return Darwin.kill(pid, 0) == 0 || errno == EPERM
	}

	/// Every process the group still holds.
	static func members(of group: pid_t) -> [pid_t] {
		var request: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]
		var size = 0

		guard sysctl(&request, UInt32(request.count), nil, &size, nil, 0) == 0, size > 0 else {
			return []
		}

		let count = size / MemoryLayout<kinfo_proc>.stride
		var entries = [kinfo_proc](repeating: kinfo_proc(), count: count)

		guard sysctl(&request, UInt32(request.count), &entries, &size, nil, 0) == 0 else {
			return []
		}

		return entries.prefix(size / MemoryLayout<kinfo_proc>.stride).map(\.kp_proc.p_pid)
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
	/// A process that writes a great deal without a newline, such as a progress bar, would
	/// otherwise be held here in full.
	static let longestLine = 1 << 20

	private var pending = Data()
	private let lock = NSLock()

	func take(_ data: Data) -> [String] {
		lock.lock()
		defer { lock.unlock() }

		pending.append(data)

		if pending.count > Self.longestLine {
			pending.removeFirst(pending.count - Self.longestLine)
		}

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
