import Foundation

public struct ServerAddress: Sendable, Hashable {
	public let host: String
	public let port: Int

	// ./dev exports PC_PORT_NUM, defaulting to 28080 because the acme edge container holds 8080.
	public static let defaultPort = 28080
	public static let defaultHost = "localhost"

	public static let standard = ServerAddress(checked: defaultHost, port: defaultPort)

	// URLComponents traps when given a negative port, and yields no URL for a host
	// containing whitespace. Settings lets the user type both, so an unusable address is
	// refused here. Substituting a working one would point destructive actions at a
	// server the user never asked for.
	public init?(host: String, port: Int) {
		let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)

		guard !trimmed.isEmpty,
			!trimmed.contains(where: \.isWhitespace),
			(1 ... 65535).contains(port)
		else { return nil }

		self.init(checked: trimmed, port: port)
	}

	private init(checked host: String, port: Int) {
		self.host = host
		self.port = port
	}

	public static func fromEnvironment(
		_ environment: [String: String] = ProcessInfo.processInfo.environment
	) -> ServerAddress {
		let raw = environment["PC_PORT_NUM"] ?? environment["DEV_STACK_PORT"] ?? ""
		return ServerAddress(host: defaultHost, port: Int(raw) ?? defaultPort) ?? .standard
	}

	func url(path: String, scheme: String = "http", query: [URLQueryItem] = []) -> URL {
		var components = URLComponents()
		components.scheme = scheme
		components.host = host
		components.port = port
		components.path = path
		components.queryItems = query.isEmpty ? nil : query
		return components.url!
	}
}

public final class LiveProcessComposeClient: ProcessComposeClient {
	private let address: ServerAddress
	private let session: URLSession

	public init(address: ServerAddress = .standard, session: URLSession = .shared) {
		self.address = address
		self.session = session
	}

	public func processes() async throws -> [ProcessState] {
		struct Envelope: Decodable { let data: [ProcessState] }
		let envelope: Envelope = try await get("/processes")
		return envelope.data
	}

	public func configuration(for name: String) async throws -> ProcessConfiguration {
		try await get("/process/info/\(escaped(name))")
	}

	public func projectState() async throws -> ProjectState {
		try await get("/project/state")
	}

	public func start(_ name: String) async throws {
		try await send("POST", "/process/start/\(escaped(name))")
	}

	public func stop(_ name: String) async throws {
		try await send("PATCH", "/process/stop/\(escaped(name))")
	}

	public func restart(_ name: String) async throws {
		try await send("POST", "/process/restart/\(escaped(name))")
	}

	public func stateEvents() -> AsyncThrowingStream<ProcessStateEvent, any Error> {
		socketStream(path: "/process/states/ws", query: [])
	}

	public func logMessages(for name: String, backfill: Int) -> AsyncThrowingStream<LogMessage, any Error> {
		socketStream(
			path: "/process/logs/ws",
			query: [
				URLQueryItem(name: "name", value: name),
				URLQueryItem(name: "follow", value: "true"),
				URLQueryItem(name: "offset", value: String(backfill)),
			]
		)
	}

	public func truncateLogs(for name: String) async throws {
		try await send("DELETE", "/process/logs/\(escaped(name))")
	}

	// The server drops lines when a subscriber reads too slowly, so the stream buffers
	// the newest frames rather than growing without bound.
	private func socketStream<Frame: Decodable & Sendable>(
		path: String,
		query: [URLQueryItem]
	) -> AsyncThrowingStream<Frame, any Error> {
		let task = session.webSocketTask(with: address.url(path: path, scheme: "ws", query: query))
		let decoder = JSONDecoder()

		return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(4096)) { continuation in
			// URLSessionWebSocketTask delivers one message per receive call, so the
			// handler re-arms itself until the socket fails or the stream is dropped.
			func receiveNext() {
				task.receive { result in
					switch result {
					case .success(let message):
						guard let frame: Frame = Self.decode(message, using: decoder) else {
							continuation.finish(throwing: ProcessComposeError.unreadableFrame)
							return
						}
						continuation.yield(frame)
						receiveNext()
					case .failure(let error):
						continuation.finish(throwing: error)
					}
				}
			}

			continuation.onTermination = { _ in task.cancel(with: .goingAway, reason: nil) }

			task.resume()
			receiveNext()
		}
	}

	private static func decode<Frame: Decodable>(
		_ message: URLSessionWebSocketTask.Message,
		using decoder: JSONDecoder
	) -> Frame? {
		let payload: Data? = switch message {
		case .data(let data): data
		case .string(let text): text.data(using: .utf8)
		@unknown default: nil
		}

		guard let payload else { return nil }

		return try? decoder.decode(Frame.self, from: payload)
	}

	private func escaped(_ name: String) -> String {
		name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
	}

	private func get<Response: Decodable>(_ path: String) async throws -> Response {
		let data = try await perform(URLRequest(url: address.url(path: path)))
		return try JSONDecoder().decode(Response.self, from: data)
	}

	private func send(_ method: String, _ path: String) async throws {
		var request = URLRequest(url: address.url(path: path))
		request.httpMethod = method
		_ = try await perform(request)
	}

	private func perform(_ request: URLRequest) async throws -> Data {
		let data: Data
		let response: URLResponse

		do {
			(data, response) = try await session.data(for: request)
		} catch {
			throw ProcessComposeError.unreachable(port: address.port)
		}

		guard let http = response as? HTTPURLResponse else {
			throw ProcessComposeError.unexpectedResponse(status: 0)
		}

		guard (200 ..< 300).contains(http.statusCode) else {
			struct Failure: Decodable { let error: String }
			if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
				throw ProcessComposeError.server(message: failure.error)
			}
			throw ProcessComposeError.unexpectedResponse(status: http.statusCode)
		}

		return data
	}
}
