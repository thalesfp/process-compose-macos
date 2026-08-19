import ConductorCore
import SwiftUI

struct ProcessRow: View {
	private static let controlsWidth = RowActionButtonStyle.size.width * 3 + 4

	let state: ProcessState
	let kind: ProcessKind
	let isBusy: Bool
	let start: () -> Void
	let stop: () -> Void
	let restart: () -> Void

	var body: some View {
		HStack(spacing: 10) {
			StatusDot(indicator: state.indicator, kind: kind, label: state.status.rawValue)

			Text(state.name)
				.font(.system(.body, design: .monospaced))
				.lineLimit(1)
				.truncationMode(.middle)
				.frame(minWidth: 150, idealWidth: 220, maxWidth: 340, alignment: .leading)
				.help(state.name)

			Text(state.status.rawValue)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.frame(width: 86, alignment: .leading)

			badges

			Spacer(minLength: 12)

			metrics

			controls
		}
		.padding(.vertical, 4)
	}

	@ViewBuilder
	private var badges: some View {
		HStack(spacing: 6) {
			if state.hasReadinessProbe, state.isRunning {
				Label(state.isReady ? "ready" : "starting", systemImage: state.isReady ? "checkmark" : "clock")
					.labelStyle(.titleAndIcon)
					.font(.caption)
					.foregroundStyle(state.isReady ? Color.green : Color.orange)
			}
			if state.isWatched {
				Image(systemName: "eye")
					.font(.caption)
					.foregroundStyle(.blue)
					.help("A file watcher is armed")
					.accessibilityLabel("File watcher armed")
			}
			if state.restarts > 0 {
				Text("↺\(state.restarts)")
					.font(.caption)
					.foregroundStyle(.orange)
					.help("\(state.restarts) restarts")
					.accessibilityLabel("\(state.restarts) restarts")
			}
			if case .completed = state.status, state.exitCode != 0 {
				Text("exit \(state.exitCode)")
					.font(.caption)
					.foregroundStyle(.red)
					.accessibilityLabel("Exit code \(state.exitCode)")
			}
		}
		.frame(width: 130, alignment: .leading)
	}

	/// One saturated core. Above this the figure stops being background noise.
	private static let busyCPUPercent: Double = 90

	@ViewBuilder
	private var metrics: some View {
		if kind == .task {
			taskMetrics
		} else if state.isRunning {
			HStack(spacing: 10) {
				Text(state.age.compactLabel)
				Text(state.cpuLabel)
					.foregroundStyle(state.cpuPercent >= Self.busyCPUPercent ? Color.orange : Color.secondary)
				Text(state.memoryLabel)
			}
			.font(.caption.monospacedDigit())
			.foregroundStyle(.secondary)
			.frame(width: 190, alignment: .trailing)
			.accessibilityLabel(
				"Up \(state.age.compactLabel), \(state.cpuLabel) processor, \(state.memoryLabel) memory"
			)
		} else {
			Color.clear.frame(width: 190, height: 1)
		}
	}

	/// Uptime, CPU and memory describe something that is meant to stay up. A task's
	/// facts are what it last did and what set it off.
	@ViewBuilder
	private var taskMetrics: some View {
		HStack(spacing: 10) {
			if let trigger = state.watchTriggerPath {
				Text(trigger)
					.lineLimit(1)
					.truncationMode(.head)
					.help(trigger)
			}
			if state.hasRun {
				Text("exit \(state.exitCode)")
					.foregroundStyle(state.exitCode == 0 ? Color.secondary : Color.red)
			}
		}
		.font(.caption.monospacedDigit())
		.foregroundStyle(.secondary)
		.frame(width: 190, alignment: .trailing)
	}

	@ViewBuilder
	private var controls: some View {
		if isBusy {
			ProgressView()
				.controlSize(.small)
				.frame(width: Self.controlsWidth)
				.accessibilityLabel("Working on \(state.name)")
		} else {
			HStack(spacing: 2) {
				Button(action: start) { Image(systemName: "play.fill") }
					.disabled(!state.canStart)
					.help("Start")
					.accessibilityLabel("Start \(state.name)")
				Button(action: restart) { Image(systemName: "arrow.clockwise") }
					.disabled(!state.canStop)
					.help("Restart")
					.accessibilityLabel("Restart \(state.name)")
				Button(action: stop) { Image(systemName: "stop.fill") }
					.disabled(!state.canStop)
					.help("Stop")
					.accessibilityLabel("Stop \(state.name)")
			}
			.buttonStyle(RowActionButtonStyle())
			.frame(width: Self.controlsWidth, alignment: .trailing)
		}
	}
}
