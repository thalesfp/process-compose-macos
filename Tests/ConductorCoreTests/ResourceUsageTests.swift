import Testing

@testable import ConductorCore

struct ResourceUsageTests {
	@Test("adds up what the running processes are using")
	func sumsRunningProcesses() {
		let states: [ProcessState] = [
			.init(name: "api", status: .running, memoryBytes: 140_000_000, cpuPercent: 12.5, isRunning: true),
			.init(name: "worker", status: .running, memoryBytes: 60_000_000, cpuPercent: 3.5, isRunning: true),
		]

		let usage = ResourceUsage.total(of: states)

		#expect(usage.memoryBytes == 200_000_000)
		#expect(usage.cpuPercent == 16)
	}

	@Test("ignores a stopped process still reporting its last sample")
	func ignoresStoppedProcesses() {
		let states: [ProcessState] = [
			.init(name: "api", status: .running, memoryBytes: 140_000_000, cpuPercent: 12.5, isRunning: true),
			.init(name: "relay", status: .completed, memoryBytes: 90_000_000, cpuPercent: 40, isRunning: false),
		]

		let usage = ResourceUsage.total(of: states)

		#expect(usage.memoryBytes == 140_000_000)
		#expect(usage.cpuPercent == 12.5)
	}

	@Test("reports nothing when the stack is idle")
	func idleStackUsesNothing() {
		#expect(ResourceUsage.total(of: []) == .none)
	}
}

struct ResourceFormatTests {
	@Test("drops the decimal once the number is big enough not to need it")
	func wholeNumbersAboveTen() {
		#expect(ResourceFormat.cpu(142.4) == "142%")
		#expect(ResourceFormat.cpu(10) == "10%")
	}

	@Test("keeps one decimal while the process is barely working")
	func decimalBelowTen() {
		#expect(ResourceFormat.cpu(3.25) == "3.2%")
		#expect(ResourceFormat.cpu(0) == "0.0%")
	}
}
