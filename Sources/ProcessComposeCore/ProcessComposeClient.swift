import Foundation

public protocol ProcessComposeClient: Sendable {
	func processes() async throws -> [ProcessState]
	func configuration(for name: String) async throws -> ProcessConfiguration
	func projectState() async throws -> ProjectState
	func start(_ name: String) async throws
	func stop(_ name: String) async throws
	func restart(_ name: String) async throws
	func stateEvents() -> AsyncThrowingStream<ProcessStateEvent, any Error>
	/// Replays the last `backfill` lines, then follows the process until the stream is dropped.
	func logMessages(for name: String, backfill: Int) -> AsyncThrowingStream<LogMessage, any Error>
	func truncateLogs(for name: String) async throws
}

public enum ProcessComposeError: Error, Sendable, Equatable {
	case unreachable(port: Int)
	case server(message: String)
	case unexpectedResponse(status: Int)
	case streamClosed
	case unreadableFrame
}

extension ProcessComposeError: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .unreachable(let port): "No process-compose server on port \(port)"
		case .server(let message): message
		case .unexpectedResponse(let status): "Server replied \(status)"
		case .streamClosed: "The event stream closed"
		case .unreadableFrame: "The server sent a message the app could not read"
		}
	}
}
