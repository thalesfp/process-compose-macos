import Foundation

public struct ResourceUsage: Sendable, Hashable {
	public let cpuPercent: Double
	public let memoryBytes: Int64

	public init(cpuPercent: Double, memoryBytes: Int64) {
		self.cpuPercent = cpuPercent
		self.memoryBytes = memoryBytes
	}

	public static let none = ResourceUsage(cpuPercent: 0, memoryBytes: 0)

	/// Only running processes hold resources; a stopped one still reports its last
	/// sample, which would otherwise be counted forever.
	public static func total(of states: [ProcessState]) -> ResourceUsage {
		let running = states.filter(\.isRunning)

		return ResourceUsage(
			cpuPercent: running.reduce(0) { $0 + $1.cpuPercent },
			memoryBytes: running.reduce(0) { $0 + $1.memoryBytes }
		)
	}
}

/// How the CPU and memory numbers read on screen.
public enum ResourceFormat {
	/// Percentages are summed across a process tree, so they pass 100 on a busy
	/// multicore machine; the decimal only earns its place below ten.
	public static func cpu(_ percent: Double) -> String {
		percent >= 10 ? String(format: "%.0f%%", percent) : String(format: "%.1f%%", percent)
	}

	public static func memory(_ bytes: Int64) -> String {
		bytes.formatted(.byteCount(style: .memory))
	}
}

extension ResourceUsage {
	public var cpuLabel: String { ResourceFormat.cpu(cpuPercent) }
	public var memoryLabel: String { ResourceFormat.memory(memoryBytes) }
}

extension ProcessState {
	public var cpuLabel: String { ResourceFormat.cpu(cpuPercent) }
	public var memoryLabel: String { ResourceFormat.memory(memoryBytes) }
}
