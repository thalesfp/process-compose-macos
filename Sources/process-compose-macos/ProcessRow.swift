import ProcessComposeCore
import SwiftUI

struct ProcessRow: View {
	private static let controlsWidth = RowActionButtonStyle.size.width * 3 + 4

	let state: ProcessState
	let kind: ProcessKind
	let isBusy: Bool
	let canStart: Bool
	let canStop: Bool
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
			if kind != .task, state.hasRun, state.exitCode != 0 {
				Text("exit \(state.exitCode)")
					.font(.caption)
					.foregroundStyle(.red)
					.accessibilityLabel("Exit code \(state.exitCode)")
			}
		}
		.frame(width: 130, alignment: .leading)
	}

	private static let metricsWidth: Double = 190

	/// The empty case still reserves the column, so the row's other columns stay aligned.
	private var metrics: some View {
		Group {
			if kind == .task {
				taskFacts
			} else if state.isRunning {
				serviceFacts
			}
		}
		.font(.caption.monospacedDigit())
		.foregroundStyle(.secondary)
		.frame(width: Self.metricsWidth, alignment: .trailing)
	}

	/// Uptime, CPU and memory describe something that is meant to stay up.
	private var serviceFacts: some View {
		let age = state.age.compactLabel
		let cpu = state.cpuLabel
		let memory = state.memoryLabel

		return HStack(spacing: 10) {
			Text(age)
			Text(cpu)
				.foregroundStyle(state.isCPUSaturated ? Color.orange : Color.secondary)
			Text(memory)
		}
		.accessibilityLabel("Up \(age), \(cpu) processor, \(memory) memory")
	}

	/// A task's facts are what it last did and what set it off.
	@ViewBuilder
	private var taskFacts: some View {
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
					.disabled(!canStart)
					.help("Start")
					.accessibilityLabel("Start \(state.name)")
				Button(action: restart) { Image(systemName: "arrow.clockwise") }
					.disabled(!canStop)
					.help("Restart")
					.accessibilityLabel("Restart \(state.name)")
				Button(action: stop) { Image(systemName: "stop.fill") }
					.disabled(!canStop)
					.help("Stop")
					.accessibilityLabel("Stop \(state.name)")
			}
			.buttonStyle(RowActionButtonStyle())
			.frame(width: Self.controlsWidth, alignment: .trailing)
		}
	}
}
