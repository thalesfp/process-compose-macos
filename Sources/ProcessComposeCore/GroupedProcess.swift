import Darwin
import Foundation

/// A child in a process group of its own, so a signal reaches whatever it spawned as well.
/// `Foundation.Process` gives its children the app's own group, which cannot be signalled
/// without signalling the app.
final class GroupedProcess: @unchecked Sendable {
	let pid: pid_t

	private let output: Int32
	private let lock = NSLock()
	private var reaped = false

	private init(pid: pid_t, output: Int32) {
		self.pid = pid
		self.output = output
	}

	enum SpawnFailure: Error, LocalizedError {
		case pipe(Int32)
		case spawn(Int32)

		var errorDescription: String? {
			switch self {
			case .pipe(let code), .spawn(let code): String(cString: strerror(code))
			}
		}
	}

	static func run(
		executable: URL,
		arguments: [String],
		workingDirectory: URL,
		environment: [String: String]
	) throws -> GroupedProcess {
		var ends: [Int32] = [0, 0]

		guard pipe(&ends) == 0 else { throw SpawnFailure.pipe(errno) }

		let reading = ends[0]
		let writing = ends[1]

		var actions: posix_spawn_file_actions_t?
		posix_spawn_file_actions_init(&actions)
		defer { posix_spawn_file_actions_destroy(&actions) }
		posix_spawn_file_actions_adddup2(&actions, writing, STDOUT_FILENO)
		posix_spawn_file_actions_adddup2(&actions, writing, STDERR_FILENO)
		posix_spawn_file_actions_addclose(&actions, reading)
		posix_spawn_file_actions_addclose(&actions, writing)
		posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)

		var attributes: posix_spawnattr_t?
		posix_spawnattr_init(&attributes)
		defer { posix_spawnattr_destroy(&attributes) }
		posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
		posix_spawnattr_setpgroup(&attributes, 0)

		var pid: pid_t = 0
		let started = withCStrings([executable.path] + arguments) { argv in
			withCStrings(environment.map { "\($0.key)=\($0.value)" }) { envp in
				posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
			}
		}

		close(writing)

		guard started == 0 else {
			close(reading)
			throw SpawnFailure.spawn(started)
		}

		return GroupedProcess(pid: pid, output: reading)
	}

	/// Everything the child printed. Ends when the last writer closes the pipe, which
	/// killing the group guarantees.
	func read() -> String {
		var data = Data()
		var buffer = [UInt8](repeating: 0, count: 65536)

		while true {
			let count = Darwin.read(output, &buffer, buffer.count)
			guard count > 0 else { break }
			data.append(contentsOf: buffer[0 ..< count])
		}

		close(output)

		return String(decoding: data, as: UTF8.self)
	}

	/// Whether anything in the group is still there. A wrapper that starts the server and
	/// exits leaves the work behind it, so the leader going is not the group going.
	var hasMembers: Bool {
		kill(-pid, 0) == 0
	}

	/// Whether the child is over, without reaping it.
	var hasExited: Bool {
		lock.lock()
		let done = reaped
		lock.unlock()

		if done { return true }

		var info = siginfo_t()
		let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)

		return result != 0 || info.si_pid == pid
	}

	/// Hands over what the child prints as it arrives, and returns when the pipe ends.
	func drain(into handler: (Data) -> Void) {
		var buffer = [UInt8](repeating: 0, count: 65536)

		while true {
			let count = Darwin.read(output, &buffer, buffer.count)
			guard count > 0 else { break }
			handler(Data(buffer[0 ..< count]))
		}

		close(output)
	}

	/// Waits for the child to exit without reaping it, so the pid stays claimed and the
	/// caller decides when the group is done. Closing stdout is not exiting, so a check
	/// that goes quiet still has to be waited for.
	func waitUntilExit(polling interval: useconds_t = 20_000) {
		var info = siginfo_t()

		while true {
			lock.lock()
			let done = reaped
			lock.unlock()

			if done { return }

			let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)

			if result != 0 || info.si_pid == pid { return }

			usleep(interval)
		}
	}

	/// Collects the exit status. Nothing signals the group afterwards, since the system is
	/// free to hand the number to somebody else once the last of the group is reaped.
	@discardableResult
	func reap() -> Int32 {
		lock.lock()
		defer { lock.unlock() }

		guard !reaped else { return -1 }

		var raw: Int32 = 0
		waitpid(pid, &raw, 0)
		reaped = true

		return raw & 0x7F == 0 ? (raw >> 8) & 0xFF : -1
	}

	func signal(_ number: Int32) {
		lock.lock()
		defer { lock.unlock() }

		guard !reaped else { return }

		kill(-pid, number)
	}
}

private func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
	var pointers = strings.map { strdup($0) }
	pointers.append(nil)
	defer { pointers.forEach { free($0) } }

	return body(pointers)
}
