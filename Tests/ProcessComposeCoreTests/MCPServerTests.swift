import Foundation
import Testing

@testable import ProcessComposeCore

@MainActor
struct MCPServerTests {
	@Test("points an MCP client at the SSE endpoint process-compose serves")
	func buildsTheSSEURL() async {
		let viewModel = MCPServerViewModel(probe: StubProbe())

		viewModel.watch(ServerAddress(host: "localhost", port: 28081))

		#expect(viewModel.url?.absoluteString == "http://localhost:28081/sse")
	}

	@Test("reports the server as answering once the endpoint replies")
	func reportsAReachableServer() async {
		let probe = StubProbe(reachable: true)
		let viewModel = MCPServerViewModel(probe: probe)
		viewModel.watch(ServerAddress(host: "localhost", port: 28081))

		await viewModel.check()

		#expect(viewModel.isReachable)
		#expect(probe.asked.first == "http://localhost:28081/sse")
	}

	@Test("reports nothing to connect to when the endpoint is silent")
	func reportsASilentServer() async {
		let viewModel = MCPServerViewModel(probe: StubProbe(reachable: false))
		viewModel.watch(ServerAddress(host: "localhost", port: 28081))

		await viewModel.check()

		#expect(!viewModel.isReachable)
	}

	@Test("has nothing to offer when settings hold no usable MCP port")
	func offersNothingWithoutAPort() async {
		let probe = StubProbe(reachable: true)
		let viewModel = MCPServerViewModel(probe: probe)

		viewModel.watch(nil)
		await viewModel.check()

		#expect(viewModel.url == nil)
		#expect(!viewModel.isReachable)
		#expect(probe.asked.isEmpty)
	}

	@Test("forgets the old verdict when the port changes")
	func forgetsTheOldVerdict() async {
		let viewModel = MCPServerViewModel(probe: StubProbe(reachable: true))
		viewModel.watch(ServerAddress(host: "localhost", port: 28081))
		await viewModel.check()

		viewModel.watch(ServerAddress(host: "localhost", port: 28082))

		#expect(!viewModel.isReachable)
		#expect(viewModel.url?.absoluteString == "http://localhost:28082/sse")
	}
}

final class StubProbe: MCPServerProbe, @unchecked Sendable {
	nonisolated(unsafe) var asked: [String] = []
	private let reachable: Bool

	init(reachable: Bool = false) {
		self.reachable = reachable
	}

	func isReachable(_ url: URL) async -> Bool {
		asked.append(url.absoluteString)
		return reachable
	}
}
