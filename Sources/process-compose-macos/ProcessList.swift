import AppKit
import ProcessComposeCore
import SwiftUI

struct ProcessList: View {
	@Bindable var model: StackViewModel

	var body: some View {
		List(selection: $model.selection) {
			ForEach(model.sections) { section in
				Section {
					ForEach(section.processes) { state in
						row(for: state, kind: section.kind)
					}
				} header: {
					sectionHeader(for: section)
				}
			}
		}
		.listStyle(.inset)
	}

	/// offer different things for the same process.
	private func row(for state: ProcessState, kind: ProcessKind) -> some View {
		let name = state.name
		let start: () -> Void = { Task { await model.startProcess(name) } }
		let stop: () -> Void = { Task { await model.stopProcess(name) } }
		let restart: () -> Void = { Task { await model.restartProcess(name) } }

		return ProcessRow(
			state: state,
			kind: kind,
			isBusy: model.isBusy(name),
			canStart: model.canStart(name),
			canStop: model.canStop(name),
			start: start,
			stop: stop,
			restart: restart
		)
		.tag(name)
		.contextMenu {
			Button("Start", action: start)
				.disabled(!model.canStart(name))
			Button("Restart", action: restart)
				.disabled(!model.canStop(name))
			Button("Stop", action: stop)
				.disabled(!model.canStop(name))
			Divider()
			Button("Show Log") { model.selection = name }
			Button("Copy Name") { NSPasteboard.copy(name) }
		}
	}

	/// Namespace and role, each shown only where it changes. The sidebar names the
	/// project, so the list does not repeat it.
	private func sectionHeader(for section: StackSection) -> some View {
		// A pinned header only reserves the height of its content, so the breathing room
		// goes on the labels themselves. Padding the container makes it cover the first row.
		VStack(alignment: .leading, spacing: 6) {
			if section.isFirstInNamespace {
				Text(section.namespace)
					.font(.title3.weight(.semibold))
					.foregroundStyle(.secondary)
					.padding(.top, 14)
			}
			if section.showsKind {
				Text(section.kind.label)
					.font(.body.weight(.medium))
					.foregroundStyle(.tertiary)
					.padding(.top, section.isFirstInNamespace ? 0 : 14)
					.padding(.leading, 10)
			}
		}
		.textCase(nil)
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}
