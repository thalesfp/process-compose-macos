import ProcessComposeCore
import SwiftUI

struct PowerControl: View {
	let model: StackViewModel
	let server: ServerSupervisor

	var body: some View {
		if power.isWorking {
			ProgressView()
				.controlSize(.small)
				.accessibilityLabel("Working on the stack")
		} else {
			Button(power.title, systemImage: "power") { power.perform() }
			.labelStyle(.titleAndIcon)
			.disabled(!power.isEnabled)
			.help(power.stops ? "Stop every running process" : "Start every process the stack defines")
		}
	}

	private var power: PowerAction {
		PowerAction(model: model, server: server)
	}
}
