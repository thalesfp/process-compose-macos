import ProcessComposeCore
import SwiftUI

/// Start and stop for one project. The sidebar names the row it sits on, the Stack menu
/// names whichever project the sidebar has selected, and both get the same two actions
/// from here rather than each wiring its own.
struct ProjectActions: View {
	let model: StackViewModel
	let project: String?

	var body: some View {
		Button(title("Start All")) { run(model.startProject) }
			.disabled(!allows(model.canStartProject))

		Button(title("Stop All") + "...") { project.map { model.stopTarget = .project($0) } }
			.disabled(!allows(model.canStopProject))
	}

	private func title(_ verb: String) -> String {
		project.map { "\(verb) in \($0)" } ?? verb
	}

	private func allows(_ predicate: (String) -> Bool) -> Bool {
		project.map(predicate) ?? false
	}

	private func run(_ action: @escaping (String) async -> Void) {
		guard let project else { return }

		Task { await action(project) }
	}
}
