import ProcessComposeCore

/// The power button, its menu item and the empty window's button. With no server up,
/// starting the stack is starting the server, whose `up` starts every process.
@MainActor
struct PowerAction {
	let model: StackViewModel
	let server: ServerSupervisor

	/// The model keeps the last states it heard after the server goes, so with no server up
	/// the button starts one whatever those states say.
	var stops: Bool {
		!startsServer && model.power == .canStop
	}

	var title: String {
		stops ? "Stop Stack…" : "Start Stack"
	}

	var isWorking: Bool {
		model.isChangingStack || server.isLaunching || server.isStopping
	}

	var isEnabled: Bool {
		!isWorking && !model.isQuitting && (model.canChangePower || startsServer)
	}

	func perform() {
		guard startsServer else { return model.togglePower() }

		Task { await server.start() }
	}

	private var startsServer: Bool {
		guard case .disconnected = model.connection else { return false }

		return server.canStart
	}
}
