import Foundation
import Observation

/// process-compose can host an MCP server alongside its REST API, exposing the same
/// project to an MCP client. It starts with the instance and cannot be toggled, so all
/// the app can do is say whether it is answering.
public protocol MCPServerProbe: Sendable {
	func isReachable(_ url: URL) async -> Bool
}

public struct LiveMCPServerProbe: MCPServerProbe {
	private let session: URLSession

	public init(session: URLSession = .shared) {
		self.session = session
	}

	public func isReachable(_ url: URL) async -> Bool {
		var request = URLRequest(url: url)
		request.timeoutInterval = 2
		request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

		// An SSE response never finishes, so the headers are read and the body dropped.
		guard let (bytes, response) = try? await session.bytes(for: request) else { return false }
		bytes.task.cancel()

		guard let http = response as? HTTPURLResponse else { return false }

		return Self.answersSSE(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"))
	}

	// A server with SPA fallback routing answers 200 for any path, so the media type is
	// what separates an MCP endpoint from an unrelated service on the same port.
	static func answersSSE(status: Int, contentType: String?) -> Bool {
		guard status == 200, let contentType else { return false }

		// RFC 9110 puts optional parameters after a semicolon, so only the part before it
		// names the media type.
		let mediaType = contentType.prefix { $0 != ";" }
			.trimmingCharacters(in: .whitespaces)
			.lowercased()

		return mediaType == "text/event-stream"
	}
}

@MainActor
@Observable
public final class MCPServerViewModel {
	public private(set) var isReachable = false
	public private(set) var url: URL?

	private let probe: any MCPServerProbe
	private let pollInterval: Duration
	private var pollTask: Task<Void, Never>?

	public init(probe: any MCPServerProbe = LiveMCPServerProbe(), pollInterval: Duration = .seconds(5)) {
		self.probe = probe
		self.pollInterval = pollInterval
	}

	public func watch(_ address: ServerAddress?) {
		let endpoint = address?.url(path: "/sse")
		guard endpoint != url else { return }

		url = endpoint
		isReachable = false
		pollTask?.cancel()
		pollTask = endpoint == nil ? nil : Reconnecting.loop(every: pollInterval) { [weak self] in
			await self?.check()
		}
	}

	func check() async {
		guard let url else { return }

		let reachable = await probe.isReachable(url)
		guard reachable != isReachable else { return }

		isReachable = reachable
	}
}
