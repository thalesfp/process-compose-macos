import Foundation

@testable import ProcessComposeCore

/// Waits for something the stream or a watch task drives, so a test never races it.
/// A real deadline rather than a yield count: yields say nothing about work that is
/// waiting on a clock or on another actor.
@MainActor
func settle(until condition: () -> Bool, within limit: Duration = .seconds(5)) async {
	let deadline = ContinuousClock.now.advanced(by: limit)

	while !condition(), ContinuousClock.now < deadline {
		try? await Task.sleep(for: .milliseconds(10))
	}
}

/// Holds a test at the point where the server has answered and the event stream is open,
/// so it can assert on state that only holds while the connection is live.
@MainActor
func settle(_ viewModel: StackViewModel) async {
	await settle(until: { viewModel.connection == .connected })
}
