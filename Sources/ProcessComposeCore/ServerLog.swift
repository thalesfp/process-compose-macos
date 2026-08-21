import Foundation
import Observation

/// What the server itself printed. Its processes stream their own logs over the API, so
/// this carries the startup and shutdown of the server.
@MainActor
@Observable
public final class ServerLog {
	public var lines: [LogLine] { buffer.lines }

	public var maxLines: Int {
		get { buffer.maxLines }
		set { buffer.maxLines = newValue }
	}

	private var buffer: LogBuffer

	public init(maxLines: Int = 2000) {
		self.buffer = LogBuffer(maxLines: maxLines)
	}

	public func append(_ text: String) {
		buffer.append(text)
	}

	public func clear() {
		buffer.removeAll()
	}
}
