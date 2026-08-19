import ConductorCore
import SwiftUI

extension ProcessIndicator {
	var color: Color {
		switch self {
		case .healthy: .green
		case .running: .mint
		case .waiting: .orange
		case .watching: .blue
		case .idle: .secondary
		case .failed: .red
		}
	}

}

/// A filled dot means something checked the process and it answered. A hollow one
/// means it is only known to be alive, which is all process-compose can see without
/// a readiness probe.
struct StatusDot: View {
	let indicator: ProcessIndicator
	let kind: ProcessKind
	let label: String

	var body: some View {
		Group {
			switch (kind, indicator) {
			case (.service, .running):
				Circle().strokeBorder(indicator.color, lineWidth: 1.8)
			case (.service, _):
				Circle().fill(indicator.color)
			case (.task, .watching), (.task, .idle):
				shape.strokeBorder(indicator.color, lineWidth: 1.8)
			case (.task, _):
				shape.fill(indicator.color)
			}
		}
		.frame(width: 9, height: 9)
		.accessibilityLabel("\(kind.rawValue), \(label)")
	}

	/// A task is discrete work, so it is square; a service is continuous, so it is round.
	private var shape: RoundedRectangle {
		RoundedRectangle(cornerRadius: 2)
	}
}
