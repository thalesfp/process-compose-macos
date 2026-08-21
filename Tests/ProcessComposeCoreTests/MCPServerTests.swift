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

	@Test("ignores a probe result for an endpoint the user has already left")
	func ignoresAStaleProbeResult() async {
		let probe = EndpointChangingProbe()
		let viewModel = MCPServerViewModel(probe: probe)
		probe.viewModel = viewModel
		viewModel.watch(ServerAddress(host: "localhost", port: 28081))

		await viewModel.check()

		#expect(viewModel.url == nil)
		#expect(!viewModel.isReachable)
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

struct MCPProbeTests {
	@Test("treats an event stream on the MCP port as an answering server")
	func acceptsAnEventStream() {
		#expect(LiveMCPServerProbe.answersSSE(status: 200, contentType: "text/event-stream; charset=utf-8"))
	}

	@Test("ignores a web page served on the MCP port")
	func rejectsAWebPage() {
		#expect(!LiveMCPServerProbe.answersSSE(status: 200, contentType: "text/html; charset=utf-8"))
	}

	@Test("ignores a media type that merely starts like an event stream")
	func rejectsALookalikeMediaType() {
		#expect(!LiveMCPServerProbe.answersSSE(status: 200, contentType: "text/event-streaming"))
	}

	@Test("ignores a response that names no media type")
	func rejectsAMissingMediaType() {
		#expect(!LiveMCPServerProbe.answersSSE(status: 200, contentType: nil))
	}

	@Test("ignores an event stream the server refused to serve")
	func rejectsANonSuccessStatus() {
		#expect(!LiveMCPServerProbe.answersSSE(status: 404, contentType: "text/event-stream"))
	}
}

/// Drops the watched endpoint while the probe is in flight, so `check` resumes against an
/// address the view model has already moved off.
final class EndpointChangingProbe: MCPServerProbe, @unchecked Sendable {
	nonisolated(unsafe) weak var viewModel: MCPServerViewModel?

	func isReachable(_ url: URL) async -> Bool {
		await MainActor.run { viewModel?.watch(nil) }

		return true
	}
}

/// `watch` starts a poll of its own, so the test's own call is not the only writer here.
final class StubProbe: MCPServerProbe, @unchecked Sendable {
	private let lock = NSLock()
	private var probed: [String] = []
	private let reachable: Bool

	init(reachable: Bool = false) {
		self.reachable = reachable
	}

	var asked: [String] {
		lock.lock()
		defer { lock.unlock() }
		return probed
	}

	func isReachable(_ url: URL) async -> Bool {
		record(url.absoluteString)

		return reachable
	}

	private func record(_ url: String) {
		lock.lock()
		defer { lock.unlock() }

		probed.append(url)
	}
}
