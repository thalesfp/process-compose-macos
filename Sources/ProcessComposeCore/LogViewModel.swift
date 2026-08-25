import Foundation
import Observation

@MainActor
@Observable
public final class LogViewModel {
	public var lines: [LogLine] { buffer.lines }
	public private(set) var selected: String?
	public private(set) var isStreaming = false
	public private(set) var lastError: String?

	/// Whether the pane pins itself to the newest line. Owned by the view.
	public var isFollowing = true

	/// The substring the pane shows lines for. Cleared with the selection, because a
	/// filter written for one process is rarely the one wanted for the next.
	public var filter = ""

	public var visibleLines: [LogLine] {
		LogFilter.matching(lines, filter: filter)
	}

	/// How many lines the pane keeps.
	public var maxLines: Int {
		get { buffer.maxLines }
		set { buffer.maxLines = newValue }
	}

	/// How many lines the server replays when a stream opens.
	public var backfill: Int

	private var buffer: LogBuffer
	private var client: any ProcessComposeClient
	private let retryDelay: Duration
	private var streamTask: Task<Void, Never>?

	public init(
		client: any ProcessComposeClient,
		maxLines: Int = 2000,
		backfill: Int = 300,
		retryDelay: Duration = .seconds(2)
	) {
		self.client = client
		self.buffer = LogBuffer(maxLines: maxLines)
		self.backfill = backfill
		self.retryDelay = retryDelay
	}

	/// Points the view model at a different server and reopens the current stream.
	public func use(_ client: any ProcessComposeClient) {
		let current = selected
		select(nil)
		self.client = client
		select(current)
	}

	public func select(_ name: String?) {
		guard name != selected else { return }

		streamTask?.cancel()
		selected = name
		filter = ""
		buffer.removeAll()
		lastError = nil
		isStreaming = false

		guard name != nil else {
			streamTask = nil
			return
		}

		streamTask = Reconnecting.loop(every: retryDelay) { [weak self] in
			await self?.stream()
		}
	}

	public func clear() async {
		guard let selected else { return }

		buffer.removeAll()

		do {
			try await client.truncateLogs(for: selected)
		} catch {
			lastError = error.localizedDescription
		}
	}

	/// One connection attempt: replay the backfill, then follow until the socket ends.
	public func stream() async {
		guard let name = selected else { return }

		isStreaming = true
		defer { isStreaming = false }

		do {
			for try await message in client.logMessages(for: name, backfill: backfill) {
				guard message.processName == name || message.processName.isEmpty else { continue }
				append(message)
			}
		} catch is CancellationError {
			return
		} catch {
			lastError = error.localizedDescription
		}
	}

	private func append(_ message: LogMessage) {
		buffer.append(message.message)
	}
}
