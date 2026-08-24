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
	private var finished = false
	/// Each managed group with the identities of the members it was seen holding. A group id
	/// is reused once its group is gone, so a member has to still be the one that was noted.
	private var known: [pid_t: Set<ServerOwner>] = [:]
	private var notedAt: UInt64 = 0

	private let isOurs: Bool

	private init(pid: pid_t, output: Int32, isOurs: Bool = true) {
		self.pid = pid
		self.output = output
		self.isOurs = isOurs

		known = UnixProcess.groups(under: pid)
		if known[pid] == nil, let started = UnixProcess.startedAt(pid) {
			known[pid] = [ServerOwner(pid: pid, startedAt: started)]
		}
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

	/// Takes hold of a group an earlier run left behind. POSIX only reserves a group id
	/// while the group lives, so a record that outlived its group can name an unrelated one:
	/// a member has to be recognised before anything is signalled. Nothing is reaped here,
	/// since this process never forked it.
	static func adopt(group: pid_t, members: [pid_t: Set<ServerOwner>]) -> GroupedProcess? {
		guard group > 0 else { return nil }

		// Still there, still the same process, and still in the group it was recorded in. A
		// service that outlived its group says nothing about who holds that number now.
		var confirmed: [pid_t: Set<ServerOwner>] = [:]

		for (recorded, identities) in members {
			let present = identities.filter { $0.isRunning && UnixProcess.group(of: $0.pid) == recorded }

			if !present.isEmpty { confirmed[recorded] = present }
		}

		guard !confirmed.isEmpty else { return nil }

		let taken = GroupedProcess(pid: group, output: -1, isOurs: false)
		taken.known = confirmed

		return taken
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

		return GroupedProcess(pid: pid, output: reading, isOurs: true)
	}

	/// The end of what the child printed. Reading never stops early, since a full pipe would
	/// block the child, but only the tail is kept: the fault a check reports is its last
	/// line, and a noisy binary would otherwise be held in memory in full.
	static let keptOutput = 1 << 20

	func read() -> String {
		var data = Data()
		var buffer = [UInt8](repeating: 0, count: 65536)

		while true {
			let count = Darwin.read(output, &buffer, buffer.count)
			guard count > 0 else { break }

			data.append(contentsOf: buffer[0 ..< count])

			if data.count > Self.keptOutput {
				data.removeFirst(data.count - Self.keptOutput)
			}
		}

		close(output)

		return String(decoding: data, as: UTF8.self)
	}

	/// Whether anything in the group is still there. A wrapper that starts the server and
	/// exits leaves the work behind it, so the leader going is not the group going.
	/// Whether anything the app started is still there. The launch group's own number is
	/// not enough: it is handed out again once the group is gone.
	var hasMembers: Bool {
		lock.lock()
		defer { lock.unlock() }

		return !liveMembers().isEmpty
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

	/// Looks now for what the group has started. The leader can start its services and exit
	/// within a few milliseconds, and once it is gone nothing points at them.
	func track() {
		noteManagedGroups(force: true)
	}



	// Walking the process table is not free, so it is walked at most twice a second while
	// the leader lives.
	private func noteManagedGroups(force: Bool = false) {
		let now = DispatchTime.now().uptimeNanoseconds

		lock.lock()
		let due = force || now &- notedAt > 500_000_000
		if due { notedAt = now }
		lock.unlock()

		guard due else { return }

		lock.lock()
		let seeds = Set(known.values.flatMap { $0 }.filter(\.isRunning).map(\.pid))
		let seedGroups = Set(known.keys).union([pid])
		lock.unlock()

		// Seeded from everything known to be alive, not only the launch group: a stack that
		// moved out of it goes on starting services from wherever it is now.
		let found = UnixProcess.groups(from: seeds, groups: seedGroups)

		lock.lock()
		for (group, members) in found {
			known[group, default: []].formUnion(members)
		}
		lock.unlock()
	}

	/// Waits for the child to exit without reaping it, so the pid stays claimed and the
	/// caller decides when the group is done. Closing stdout is not exiting, so a check
	/// that goes quiet still has to be waited for.
	func waitUntilExit(polling interval: useconds_t = 20_000) {
		var info = siginfo_t()

		while true {
			guard isOurs else {
				if !hasMembers { return }
				usleep(interval)
				continue
			}

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

		// waitpid answers only for a child of this process, and an adopted group is not one.
		guard isOurs, !reaped else { return -1 }

		var raw: Int32 = 0
		waitpid(pid, &raw, 0)
		reaped = true

		return raw & 0x7F == 0 ? (raw >> 8) & 0xFF : -1
	}

	/// Reaping the leader is not the end of the group: a wrapper that starts the server and
	/// exits is reaped while the stack it left behind still has to be signalled. The id is
	/// only free for reuse once nothing is left, so that is what closes signalling.
	///
	/// process-compose puts each process it runs in a group of its own, so its services are
	/// not in this one. They are noted on the way past and signalled too, since by the time
	/// the leader is gone nothing points at them any more.
	/// How far a signal reaches.
	enum Reach {
		/// The launch group alone. process-compose runs its own shutdown for the services it
		/// manages, in its own order and with its own timeouts, and signalling them here
		/// would end them before it had the chance.
		case leader
		/// Everything seen: the launch group, and each service with the group it leads. This
		/// is for after the orderly shutdown has had its time and not taken it.
		case everything
	}

	func signal(_ number: Int32, reach: Reach = .everything) {
		noteManagedGroups(force: true)

		lock.lock()
		defer { lock.unlock() }

		guard !finished else { return }

		let live = liveMembers()

		if reach == .everything {
			// Each member by name, since one remembered from before it moved would be missed
			// by a signal to the group it was in then; and each group that still holds one of
			// them, which is what reaches anything started since.
			for member in live { kill(member.pid, number) }

			for group in liveGroups() { kill(-group, number) }
		} else if let control = controlGroup() {
			kill(-control, number)
		}

		if live.isEmpty { finished = true }
	}

	/// What each group is holding now, as identities that can be recorded and recognised
	/// again later.
	var membership: [pid_t: Set<ServerOwner>] {
		lock.lock()
		defer { lock.unlock() }

		// Pruning is what drops a process from the group it has left, so this reports each
		// one under the group holding it now.
		_ = liveGroups()

		return known
	}

	/// Everything seen under the launch group that is still the process it was. The kernel
	/// cannot report forks here, since NOTE_TRACK is not supported on macOS, so this is what
	/// the walks of the process table have found.
	private func liveMembers() -> Set<ServerOwner> {
		var live: Set<ServerOwner> = []

		for (group, members) in known {
			let running = members.filter(\.isRunning)

			if running.isEmpty {
				known[group] = nil
			} else {
				live.formUnion(running)
			}
		}

		return live
	}

	/// The group to ask to stop: the one the stack was launched in while it still holds
	/// something, and otherwise the one holding what has been there longest, since a server
	/// outlives the services it starts. A group whose number has been handed on is never it.
	private func controlGroup() -> pid_t? {
		let live = liveGroups()

		if live.contains(pid) { return pid }

		return live.min { left, right in
			(known[left]?.map(\.startedAt).min() ?? 0) < (known[right]?.map(\.startedAt).min() ?? 0)
		}
	}

	/// The groups still holding a member this process saw them hold, the launch group
	/// included. A group whose members have all gone is forgotten, since its number is then
	/// free for something else to be given.
	private func liveGroups() -> [pid_t] {
		var live: [pid_t] = []

		for (group, members) in known {
			// Still running, and still in this group. A process that has moved on says
			// nothing about who holds the number it left, and the number is handed out again
			// once the group is empty.
			let present = members.filter { $0.isRunning && UnixProcess.group(of: $0.pid) == group }

			if present.isEmpty {
				known[group] = nil
			} else {
				known[group] = present
				live.append(group)
			}
		}

		return live
	}
}

private func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
	var pointers = strings.map { strdup($0) }
	pointers.append(nil)
	defer { pointers.forEach { free($0) } }

	return body(pointers)
}
