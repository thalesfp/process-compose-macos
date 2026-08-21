import Foundation

/// Runs an attempt over and over until the task is cancelled, pausing between tries.
enum Reconnecting {
	static func loop(
		every delay: Duration,
		_ attempt: @escaping @Sendable () async -> Void
	) -> Task<Void, Never> {
		Task {
			while !Task.isCancelled {
				await attempt()
				guard !Task.isCancelled else { return }
				try? await Task.sleep(for: delay)
			}
		}
	}
}
