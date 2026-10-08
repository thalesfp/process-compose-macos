import Foundation
import Testing

@testable import ProcessComposeCore

@MainActor
struct StackViewModelTests {
	@Test("stops reporting a project once its server is gone")
	func forgetsTheProjectOnDisconnect() async {
		let client = StubClient(processes: [
			.init(name: "chatbot", namespace: "ai", status: .running, isRunning: true)
		])
		let viewModel = StackViewModel(client: client)

		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.project == nil)
		#expect(viewModel.uptime == nil)
	}

	@Test("lists every process the server reports")
	func listsProcessesFromInitialLoad() async {
		let client = StubClient(processes: [
			.init(name: "chatbot", namespace: "ai", status: .running, isRunning: true),
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: client)

		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.processes.map(\.name) == ["chatbot", "api"])
	}

	@Test("opens on the first project and shows only its processes")
	func showsOneProjectAtATime() async {
		let client = StubClient(processes: [
			.init(name: "chatbot", namespace: "ai", status: .running, isRunning: true),
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["chatbot": "acme-ai-chatbot", "api": "acme/api"]
		let viewModel = StackViewModel(client: client)

		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.projects.map(\.name) == ["acme", "acme-ai-chatbot"])
		#expect(viewModel.selectedProject == "acme")
		#expect(viewModel.visibleProcesses.map(\.name) == ["api"])
	}

	@Test("shows the other project's processes once it is selected")
	func switchesProject() async {
		let client = StubClient(processes: [
			.init(name: "chatbot", namespace: "ai", status: .running, isRunning: true),
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["chatbot": "acme-ai-chatbot", "api": "acme/api"]
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()
		viewModel.selection = "api"

		viewModel.select(project: "acme-ai-chatbot")

		#expect(viewModel.visibleProcesses.map(\.name) == ["chatbot"])
		#expect(viewModel.selection == nil)
	}

	@Test("keeps the project chosen before the connection when the stack still defines it")
	func keepsRestoredProject() async {
		let client = StubClient(processes: [
			.init(name: "chatbot", namespace: "ai", status: .running, isRunning: true),
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["chatbot": "acme-ai-chatbot", "api": "acme/api"]
		let viewModel = StackViewModel(client: client)
		viewModel.select(project: "acme-ai-chatbot")

		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.selectedProject == "acme-ai-chatbot")
	}

	@Test("falls back to the first project when the chosen one is gone")
	func fallsBackToFirstProject() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api"]
		let viewModel = StackViewModel(client: client)
		viewModel.select(project: "retired-repo")

		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.selectedProject == "acme")
	}

	@Test("gathers processes with no repo under one project")
	func gathersUngroupedProcesses() async {
		let client = StubClient(processes: [
			.init(name: "stray", namespace: "misc", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: client)

		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.selectedProject == "other")
		#expect(viewModel.visibleProcesses.map(\.name) == ["stray"])
	}

	@Test("applies a live state change from the event stream")
	func appliesLiveStateChange() async {
		let client = StubClient(processes: [
			.init(name: "relay", namespace: "relay", status: .disabled),
		])
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		client.emit(.init(
			state: .init(name: "relay", namespace: "relay", status: .running, isRunning: true)
		))
		client.finishStream()
		await session.value

		#expect(viewModel.processes.first?.status == .running)
		#expect(viewModel.processes.first?.isRunning == true)
	}

	@Test("reports the port when no server answers")
	func reportsUnreachableServer() async {
		let client = StubClient(loadFailure: ProcessComposeError.unreachable(port: 28080))
		let viewModel = StackViewModel(client: client)

		await viewModel.observe()

		#expect(viewModel.connection == .disconnected(reason: "No process-compose server on port 28080"))
	}

	@Test("names the process that failed to start")
	func surfacesStartFailure() async {
		let client = StubClient(processes: [.init(name: "relay", status: .disabled)])
		client.actionFailure = ProcessComposeError.server(message: "no such process: relay")
		let viewModel = StackViewModel(client: client)
		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		await viewModel.startProcess("relay")

		#expect(viewModel.lastError == "relay: no such process: relay")
		#expect(!viewModel.isBusy("relay"))

		client.finishStream()
		await session.value
	}

	@Test("clears the previous error once an action succeeds")
	func clearsErrorAfterSuccess() async {
		let client = StubClient(processes: [.init(name: "relay", status: .disabled)])
		client.actionFailure = ProcessComposeError.server(message: "boom")
		let viewModel = StackViewModel(client: client)
		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		await viewModel.startProcess("relay")
		client.actionFailure = nil
		await viewModel.startProcess("relay")

		#expect(viewModel.lastError == nil)

		client.finishStream()
		await session.value
	}

	@Test("selects no process on connect, so nothing streams until it is asked for")
	func selectsNoProcessOnConnect() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "web", namespace: "web", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: client)

		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.selection == nil)
		#expect(viewModel.selectedProcess == nil)
	}

	@Test("drops the selection when the server stops reporting that process")
	func dropsSelectionOnVanishedProcess() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()
		viewModel.selection = "api"

		let replacement = StubClient(processes: [
			.init(name: "web", namespace: "web", status: .running, isRunning: true),
		])
		replacement.finishStream()
		viewModel.use(replacement)

		// use() starts its own observation; driving one by hand as well would just
		// supersede it, so wait for the one it started.
		for _ in 0 ..< 1000 where viewModel.selection == "api" {
			await Task.yield()
		}

		#expect(viewModel.selection == nil)
	}

	@Test("keeps a selection the server still reports")
	func keepsLiveSelection() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "web", namespace: "web", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()
		viewModel.selection = "web"

		await viewModel.observe()

		#expect(viewModel.selection == "web")
	}

	@Test("starts every process the stack defines")
	func startsTheWholeStack() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed),
			.init(name: "worker", namespace: "api", status: .completed),
		])
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		await viewModel.startStack()

		#expect(client.started == ["api", "worker"])
		#expect(viewModel.lastError == nil)
	}

	@Test("leaves a process the config disabled switched off")
	func skipsDisabledProcesses() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed),
			.init(name: "houston-api", namespace: "houston", status: .disabled),
		])
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		await viewModel.startStack()

		#expect(client.started == ["api"])

		client.finishStream()
		await session.value
	}

	@Test("stops every running process and leaves the stopped ones alone")
	func stopsTheWholeStack() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .completed),
		])
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		await viewModel.stopStack()

		#expect(client.stopped == ["api"])

		client.finishStream()
		await session.value
	}

	@Test("names the processes that refused to start")
	func reportsProcessesThatRefusedToStart() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed),
			.init(name: "worker", namespace: "api", status: .completed),
		])
		client.refusingProcesses = ["worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		await viewModel.startStack()

		#expect(client.started == ["api", "worker"])
		#expect(viewModel.lastError == "Could not start worker")

		client.finishStream()
		await session.value
	}

	@Test("offers to start the stack when every process is stopped")
	func offersToStartWhenIdle() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed),
		])
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.power == .canStart)
	}

	@Test("offers to stop the stack while a process runs")
	func offersToStopWhileRunning() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .completed),
		])
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.power == .canStop)
	}

	@Test("refuses to power the stack while the server is unreachable")
	func refusesPowerWhenDisconnected() async {
		let client = StubClient(loadFailure: ProcessComposeError.unreachable(port: 28080))
		let viewModel = StackViewModel(client: client)

		await viewModel.observe()

		#expect(!viewModel.canChangePower)
	}

	@Test("offers no action for a process it does not know")
	func offersNoActionForUnknownProcess() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		#expect(!viewModel.canStart("ghost"))
		#expect(!viewModel.canStop(nil))
	}

	@Test("offers start for a stopped process and stop for a running one")
	func offersTheActionThatFitsTheProcess() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .completed),
		])
		let viewModel = StackViewModel(client: client)
		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		#expect(viewModel.canStop("api"))
		#expect(!viewModel.canStart("api"))
		#expect(viewModel.canStart("worker"))
		#expect(!viewModel.canStop("worker"))

		client.finishStream()
		await session.value
	}

	@Test("says how far a stop reaches when other projects are running too")
	func namesEveryProjectAStopReaches() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "chatbot", namespace: "ai", status: .running, isRunning: true),
		])
		client.workingDirs = ["chatbot": "acme-ai-chatbot", "api": "acme/api"]
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.question(for: .stopStack(promised: ["api", "chatbot"])) == "Stop 2 running processes across 2 projects?")
	}

	@Test("asks about the processes alone when one project has all of them")
	func asksAboutOneProject() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api"]
		let viewModel = StackViewModel(client: client)
		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.question(for: .stopStack(promised: ["api"])) == "Stop 1 running process?")
	}

	@Test("asks only about the project a stop names")
	func asksAboutOneProjectAlone() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
			.init(name: "chatbot", namespace: "ai", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/api", "chatbot": "acme-ai-chatbot"]
		let viewModel = StackViewModel(client: client)
		client.finishStream()

		await viewModel.observe()

		#expect(viewModel.question(for: .stopProject("acme", promised: ["api", "worker"])) == "Stop 2 running processes in acme?")
	}

	@Test("stops only the processes of the project it was given")
	func stopsOneProjectOnly() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "chatbot", namespace: "ai", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "chatbot": "acme-ai-chatbot"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		viewModel.requestStopProject("acme")
		await viewModel.perform(viewModel.confirmation!)

		#expect(client.stopped == ["api"])

		client.finishStream()
		await session.value
	}

	@Test("starts only the processes of the project it was given, leaving disabled ones off")
	func startsOneProjectOnly() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed, isRunning: false),
			.init(name: "seed", namespace: "api", status: .disabled, isRunning: false),
			.init(name: "chatbot", namespace: "ai", status: .completed, isRunning: false),
		])
		client.workingDirs = ["api": "acme/api", "seed": "acme/api", "chatbot": "acme-ai-chatbot"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		await viewModel.startProject("acme")

		#expect(client.started == ["api"])

		client.finishStream()
		await session.value
	}

	@Test("withholds project actions while a process's project is unknown")
	func withholdsProjectActionsWhenGroupingIsIncomplete() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		client.refusingConfigurations = ["worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		#expect(!viewModel.isGroupingComplete)
		#expect(!viewModel.canStopProject("acme"))
		#expect(!viewModel.canStartProject("acme"))
		#expect(viewModel.lastError == "Could not read the configuration for worker, so project actions stay off")

		client.finishStream()
		await session.value
	}

	@Test("recovers the grouping when a configuration fails once and then answers")
	func recoversGroupingAfterATransientConfigurationFailure() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		client.refusingConfigurationsOnce = ["worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		#expect(viewModel.isGroupingComplete)
		#expect(viewModel.canStopProject("acme"))
		#expect(viewModel.lastError == nil)

		client.finishStream()
		await session.value
	}

	@Test("puts a process the stream introduces into its own project")
	func groupsAProcessTheStreamIntroduces() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "extra": "acme/extra"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		client.emit(.init(
			state: .init(name: "extra", namespace: "api", status: .running, isRunning: true)
		))
		await settle(until: { viewModel.processes.count == 2 && viewModel.isGroupingComplete })

		#expect(viewModel.projects.map(\.name) == ["acme"])
		#expect(viewModel.canStopProject("acme"))

		client.finishStream()
		await session.value
	}

	@Test("withholds project actions when the stream introduces a process it cannot place")
	func withholdsActionsForAnUnplaceableStreamProcess() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "extra": "acme/extra"]
		client.refusingConfigurations = ["extra"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		#expect(viewModel.canStopProject("acme"))

		client.emit(.init(
			state: .init(name: "extra", namespace: "api", status: .running, isRunning: true)
		))
		await settle(until: { !viewModel.isGroupingComplete })

		#expect(!viewModel.canStopProject("acme"))
		#expect(viewModel.lastError == "Could not read the configuration for extra, so project actions stay off")

		client.finishStream()
		await session.value
	}

	@Test("tries again for a live process whose configuration failed the first time")
	func retriesAdoptionForALiveProcess() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "extra": "acme/extra"]
		client.refusingConfigurations = ["extra"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		client.emit(.init(
			state: .init(name: "extra", namespace: "api", status: .running, isRunning: true)
		))
		await settle(until: { !viewModel.isGroupingComplete })
		#expect(!viewModel.canStopProject("acme"))

		client.refusingConfigurations = []
		client.emit(.init(
			state: .init(name: "extra", namespace: "api", status: .running, isRunning: true)
		))
		await settle(until: { viewModel.isGroupingComplete })

		#expect(viewModel.projects.map(\.name) == ["acme"])
		#expect(viewModel.canStopProject("acme"))
		#expect(viewModel.lastError == nil)

		client.finishStream()
		await session.value
	}

	@Test("selects the project the first live process brings with it")
	func selectsAProjectIntroducedByTheStream() async {
		let client = StubClient(processes: [])
		client.workingDirs = ["extra": "acme/extra"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		#expect(viewModel.selectedProject == nil)

		client.emit(.init(
			state: .init(name: "extra", namespace: "api", status: .running, isRunning: true)
		))
		await settle(until: { viewModel.selectedProject != nil })

		#expect(viewModel.selectedProject == "acme")
		#expect(viewModel.visibleProcesses.map(\.name) == ["extra"])

		client.finishStream()
		await session.value
	}

	@Test("keeps applying state changes while a configuration read is still outstanding")
	func keepsConsumingEventsDuringAdoption() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "extra": "acme/extra"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		client.hold(["extra"])
		client.emit(.init(
			state: .init(name: "extra", namespace: "api", status: .running, isRunning: true)
		))
		await settle(until: { !viewModel.isGroupingComplete })

		client.emit(.init(
			state: .init(name: "api", namespace: "api", status: .completed, isRunning: false)
		))
		await settle(until: { viewModel.processes.first { $0.name == "api" }?.status == .completed })

		#expect(viewModel.processes.first { $0.name == "api" }?.status == .completed)
		#expect(!viewModel.isGroupingComplete)

		client.hold([])
		await settle(until: { viewModel.isGroupingComplete })

		#expect(viewModel.projects.map(\.name) == ["acme"])

		client.finishStream()
		await session.value
	}

	@Test("says what a start will leave behind before it runs")
	func asksWhenADependencyWillNotStart() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed, isRunning: false),
			.init(name: "db", namespace: "ai", status: .completed, isRunning: false),
		])
		client.workingDirs = ["api": "acme/api", "db": "chatbot-ai/app"]
		client.dependencies = ["api": ["db"]]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		viewModel.requestStartProject("acme")

		#expect(viewModel.confirmation?.target == .startProject("acme", missing: ["db"]))
		#expect(viewModel.question(for: .startProject("acme", missing: ["db"]))
			== "acme depends on db in chatbot-ai, which is not running. Start acme anyway?")
		#expect(client.started.isEmpty)

		client.finishStream()
		await session.value
	}

	@Test("starts what a process depends on before the process itself")
	func startsInDependencyOrder() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed, isRunning: false),
			.init(name: "worker", namespace: "api", status: .completed, isRunning: false),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		client.dependencies = ["api": ["worker"]]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		await viewModel.startProject("acme")

		#expect(client.started == ["worker", "api"])

		client.finishStream()
		await session.value
	}

	@Test("stops a process before the one it depends on")
	func stopsInReverseDependencyOrder() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		client.dependencies = ["api": ["worker"]]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		await viewModel.stopProject("acme")

		#expect(client.stopped == ["api", "worker"])

		client.finishStream()
		await session.value
	}

	@Test("does not start what a failed prerequisite was needed for")
	func skipsDependentsOfAFailedStart() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed, isRunning: false),
			.init(name: "worker", namespace: "api", status: .completed, isRunning: false),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		client.dependencies = ["api": ["worker"]]
		client.refusingProcesses = ["worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		await viewModel.startProject("acme")

		#expect(client.started == ["worker"])
		#expect(viewModel.lastError == "Could not start worker; did not start api")

		client.finishStream()
		await session.value
	}

	@Test("does not stop what a process that would not stop still depends on")
	func skipsPrerequisitesOfAFailedStop() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		client.dependencies = ["api": ["worker"]]
		client.refusingProcesses = ["api"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		await viewModel.stopProject("acme")

		#expect(client.stopped == ["api"])
		#expect(viewModel.lastError == "Could not stop api; did not stop worker")

		client.finishStream()
		await session.value
	}

	@Test("reads the dependencies again before acting, so a reloaded stack is honoured")
	func rereadsDependenciesBeforeABulkAction() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed, isRunning: false),
			.init(name: "worker", namespace: "api", status: .completed, isRunning: false),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		// The stack is reloaded, and api now depends on worker. Read from the cache the
		// connection filled, the order would still be the plain one.
		client.dependencies = ["api": ["worker"]]
		await viewModel.startProject("acme")

		#expect(client.started == ["worker", "api"])

		client.finishStream()
		await session.value
	}

	@Test("sends the rest of a bulk action to the server it started on")
	func keepsABulkActionOnOneServer() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		client.holdActions = true
		let other = StubClient(processes: [])
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		let bulk = Task { await viewModel.stopProject("acme") }
		await settle(until: { !viewModel.isBusy("") && client.stopped.count == 1 })

		viewModel.use(other)
		client.holdActions = false
		await bulk.value

		#expect(other.stopped.isEmpty)

		client.finishStream()
		other.finishStream()
		await session.value
	}

	@Test("keeps saying the grouping is short after an action succeeds")
	func keepsTheGroupingErrorAfterAnAction() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		client.refusingConfigurations = ["worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		await viewModel.stopProcess("api")

		#expect(viewModel.lastError == "Could not read the configuration for worker, so project actions stay off")
		#expect(!viewModel.canStopProject("acme"))

		client.finishStream()
		await session.value
	}

	@Test("acts on nothing when it cannot re-read what it is about to touch")
	func abandonsABulkActionWhenTheRefreshFails() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		// The server stops answering for one of them after the connection read it once.
		client.refusingConfigurations = ["worker"]
		await viewModel.stopProject("acme")

		#expect(client.stopped.isEmpty)
		#expect(viewModel.lastError == "Could not read the configuration for worker, so nothing was changed")

		client.finishStream()
		await session.value
	}

	@Test("holds the floor from the moment a bulk action starts reading")
	func reservesTheFloorBeforeReading() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		client.hold(["api", "worker"])
		let bulk = Task { await viewModel.stopProject("acme") }
		await settle(until: { viewModel.isChangingStack })

		// Nothing else may act while the bulk action is still reading.
		#expect(!viewModel.canStop("api"))
		#expect(!viewModel.canChangePower)
		await viewModel.stopProcess("api")

		#expect(client.stopped.isEmpty)

		client.hold([])
		await bulk.value
		client.finishStream()
		await session.value
	}

	@Test("starts nothing when the reload adds a dependency nobody was asked about")
	func abandonsAnUnconfirmedStartWhenAReloadAddsADependency() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed, isRunning: false),
			.init(name: "db", namespace: "ai", status: .completed, isRunning: false),
		])
		client.workingDirs = ["api": "acme/api", "db": "chatbot-ai/app"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		// Nothing to ask about yet, so the menu would start it outright.
		#expect(viewModel.missingDependencies(startingProject: "acme").isEmpty)

		client.dependencies = ["api": ["db"]]
		await viewModel.startProject("acme")

		#expect(client.started.isEmpty)
		#expect(viewModel.lastError == "acme depends on db, which is not running, so nothing was started")

		client.finishStream()
		await session.value
	}

	@Test("abandons a confirmed start when what it depends on changed since the question")
	func abandonsAConfirmedStartWhenConsentWentStale() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed, isRunning: false),
			.init(name: "db", namespace: "ai", status: .completed, isRunning: false),
			.init(name: "cache", namespace: "ai", status: .completed, isRunning: false),
		])
		client.workingDirs = ["api": "acme/api", "db": "chatbot-ai/app", "cache": "chatbot-ai/cache"]
		client.dependencies = ["api": ["db"]]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		viewModel.requestStartProject("acme")
		#expect(viewModel.confirmation?.target == .startProject("acme", missing: ["db"]))

		// The stack is reloaded while the question is on screen.
		client.dependencies = ["api": ["db", "cache"]]
		await viewModel.perform(viewModel.confirmation!)

		#expect(client.started.isEmpty)
		#expect(viewModel.lastError == "What acme depends on changed while the question was open, so nothing was started")

		client.finishStream()
		await session.value
	}

	@Test("takes in a process a reload moved into the project")
	func actsOnAProcessAReloadMovedIntoTheProject() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "extra", namespace: "ai", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "extra": "chatbot-ai/app"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		#expect(viewModel.projects.map(\.name) == ["acme", "chatbot-ai"])

		// The reload moves extra into acme.
		client.workingDirs["extra"] = "acme/extra"
		await viewModel.stopProject("acme")

		#expect(client.stopped.sorted() == ["api", "extra"])

		client.finishStream()
		await session.value
	}

	@Test("withdraws an open question when the app is pointed at another server")
	func withdrawsAQuestionOnAnotherServer() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		viewModel.ask(.stopProject("acme", promised: ["api"]))

		viewModel.use(StubClient(processes: []))

		#expect(viewModel.confirmation == nil)

		client.finishStream()
		await session.value
	}

	@Test("sends nothing more once the work under way is abandoned")
	func abandonsWorkAlreadyUnderWay() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		// The action is held in its preflight read, as it would be while the server behind
		// the same address is replaced.
		client.hold(["api", "worker"])
		let bulk = Task { await viewModel.stopProject("acme") }
		await settle(until: { viewModel.isChangingStack })

		// The reload would move worker across, but nothing this read found may be published.
		client.workingDirs["worker"] = "chatbot-ai/worker"
		viewModel.abandonActions()
		client.hold([])
		await bulk.value

		#expect(client.stopped.isEmpty)
		#expect(viewModel.selectedProject == "acme")
		#expect(viewModel.projects.map(\.name) == ["acme"])

		client.finishStream()
		await session.value
	}

	@Test("says nothing was stopped when the server changes before anything was sent")
	func reportsAStopAbandonedBeforeItsFirstRequest() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		client.hold(["api"])
		let bulk = Task { await viewModel.stopStack() }
		await settle(until: { viewModel.isChangingStack })

		viewModel.abandonActions()
		client.hold([])
		await bulk.value

		#expect(client.stopped.isEmpty)
		#expect(viewModel.lastError == "The server changed before anything was sent, so nothing was stopped")

		client.finishStream()
		await session.value
	}

	@Test("says how far a stop got when the server changes partway through")
	func reportsHowFarAnInterruptedStopGot() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		client.holdActions = true
		let bulk = Task { await viewModel.stopStack() }
		await settle(until: { client.stopped.count == 1 })

		viewModel.abandonActions()
		client.holdActions = false
		await bulk.value

		let first = client.stopped[0]
		let second = first == "api" ? "worker" : "api"
		#expect(client.stopped == [first])
		#expect(viewModel.lastError == "The server changed partway through: stopped \(first); never tried \(second)")

		client.finishStream()
		await session.value
	}

	@Test("leaves the message to the new connection when a stop is cut short by a move")
	func staysQuietAboutAStopCutShortByAMove() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		let viewModel = StackViewModel(client: client)
		viewModel.use(client, at: .standard)

		await settle(viewModel)
		client.holdActions = true
		let bulk = Task { await viewModel.stopStack() }
		await settle(until: { client.stopped.count == 1 })

		viewModel.use(StubClient(processes: []), at: ServerAddress(host: "localhost", port: 28099))
		client.holdActions = false
		await bulk.value

		#expect(client.stopped.count == 1)
		#expect(viewModel.lastError?.hasPrefix("The server changed") != true)

		client.finishStream()
	}

	@Test("keeps an open question when another window asks for the same server")
	func keepsAQuestionForTheSameServer() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		viewModel.use(client, at: .standard)
		viewModel.ask(.stopProject("acme", promised: ["api"]))

		// A second window builds its own client for the very same address.
		viewModel.use(StubClient(processes: []), at: .standard)

		#expect(viewModel.confirmation?.target == .stopProject("acme", promised: ["api"]))

		client.finishStream()
		await session.value
	}

	@Test("stops nothing when what is running changed while the question was open")
	func abandonsAConfirmedStopWhenTheProjectChanged() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "extra", namespace: "ai", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "extra": "chatbot-ai/app"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		viewModel.requestStopProject("acme")

		// A reload moves extra into acme while the question is on screen.
		client.workingDirs["extra"] = "acme/extra"
		await viewModel.perform(viewModel.confirmation!)

		#expect(client.stopped.isEmpty)
		#expect(viewModel.lastError == "Something started in acme while the question was open, so nothing was stopped")

		client.finishStream()
		await session.value
	}

	@Test("connects again after an address it refused is corrected back")
	func reconnectsAfterARefusedAddress() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api"]
		let viewModel = StackViewModel(client: client)
		viewModel.use(client, at: .standard)

		viewModel.refuseAddress("Settings has no usable server address")
		viewModel.use(client, at: .standard)

		#expect(viewModel.connection != .disconnected(reason: "Settings has no usable server address"))
	}

	@Test("stops nothing when a process starts while the stack question is open")
	func abandonsAConfirmedStackStopWhenSomethingStarted() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .completed, isRunning: false),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		viewModel.togglePower()
		#expect(viewModel.confirmation?.target == .stopStack(promised: ["api"]))

		// worker comes up while the question is on screen.
		client.emit(.init(
			state: .init(name: "worker", namespace: "api", status: .running, isRunning: true)
		))
		await settle(until: { viewModel.runningProcesses.count == 2 })
		await viewModel.perform(viewModel.confirmation!)

		#expect(client.stopped.isEmpty)
		#expect(viewModel.lastError == "Something started while the question was open, so nothing was stopped")

		client.finishStream()
		await session.value
	}

	@Test("stops what is still running when a process stopped while the stack question was open")
	func stopsTheRestWhenAProcessStoppedDuringTheQuestion() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		viewModel.togglePower()

		client.emit(.init(state: .init(name: "worker", namespace: "api", status: .completed, exitCode: -1)))
		await settle(until: { viewModel.runningProcesses.count == 1 })
		await viewModel.perform(viewModel.confirmation!)

		#expect(client.stopped == ["api"])
		#expect(viewModel.lastError == nil)

		client.finishStream()
		await session.value
	}

	@Test("finishes quietly when the whole stack stopped while the question was open")
	func finishesQuietlyWhenTheStackAlreadyStopped() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		viewModel.togglePower()

		client.emit(.init(state: .init(name: "api", namespace: "api", status: .completed, exitCode: -1)))
		await settle(until: { viewModel.runningProcesses.count == 0 })
		await viewModel.perform(viewModel.confirmation!)

		#expect(client.stopped.isEmpty)
		#expect(viewModel.lastError == nil)

		client.finishStream()
		await session.value
	}

	@Test("stops what is still running in a project when one stopped while the question was open")
	func stopsTheRestOfAProjectWhenOneStoppedDuringTheQuestion() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		viewModel.requestStopProject("acme")

		client.emit(.init(state: .init(name: "worker", namespace: "api", status: .completed, exitCode: -1)))
		await settle(until: { viewModel.runningProcesses.count == 1 })
		await viewModel.perform(viewModel.confirmation!)

		#expect(client.stopped == ["api"])
		#expect(viewModel.lastError == nil)

		client.finishStream()
		await session.value
	}

	@Test("finishes quietly when a whole project stopped while the question was open")
	func finishesQuietlyWhenTheProjectAlreadyStopped() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		viewModel.requestStopProject("acme")

		client.emit(.init(state: .init(name: "api", namespace: "api", status: .completed, exitCode: -1)))
		await settle(until: { viewModel.runningProcesses.count == 0 })
		await viewModel.perform(viewModel.confirmation!)

		#expect(client.stopped.isEmpty)
		#expect(viewModel.lastError == nil)

		client.finishStream()
		await session.value
	}

	@Test("does nothing with an answer captured before the work was abandoned")
	func ignoresAnAnswerCapturedBeforeAbandonment() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		viewModel.requestStopProject("acme")
		let captured = try! #require(viewModel.confirmation)

		// The server behind the address is replaced while the question is on screen.
		viewModel.abandonActions()
		await viewModel.perform(captured)

		#expect(client.stopped.isEmpty)

		client.finishStream()
		await session.value
	}

	@Test("shows a process from another project when asked to reveal it")
	func revealsAProcessInAnotherProject() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "chatbot", namespace: "ai", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "chatbot": "ai/chatbot"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		viewModel.select(project: "acme")

		viewModel.reveal("chatbot")

		#expect(viewModel.selectedProject == "ai")
		#expect(viewModel.selection == "chatbot")

		client.finishStream()
		await session.value
	}

	@Test("offers nothing new while the app is quitting")
	func offersNothingWhileQuitting() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .completed),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		viewModel.isQuitting = true

		#expect(viewModel.canChangePower == false)
		#expect(viewModel.canStop("api") == false)
		#expect(viewModel.canStart("worker") == false)
		#expect(viewModel.canStopProject("acme") == false)

		client.finishStream()
		await session.value
	}

	@Test("voids a log clear agreed to before the server was replaced")
	func voidsAClearLogAnswerAfterAbandonment() {
		let viewModel = StackViewModel(client: StubClient(processes: []))

		viewModel.ask(.clearLog("api"))
		let captured = try! #require(viewModel.confirmation)

		viewModel.abandonActions()

		#expect(viewModel.isStanding(captured) == false)
	}

	@Test("lets go of a selected process a reload moved out of the project")
	func clearsASelectionAReloadMovedAway() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		viewModel.selection = "worker"

		// The reload moves worker out of acme.
		client.workingDirs["worker"] = "chatbot-ai/worker"
		await viewModel.stopProject("acme")

		#expect(viewModel.selection == nil)
		#expect(client.stopped == ["api"])

		client.finishStream()
		await session.value
	}

	@Test("does not follow a process into a project nobody chose")
	func dropsASelectionWhenItsProjectDisappears() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "solo/worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		viewModel.select(project: "solo")
		viewModel.selection = "worker"

		// The reload moves worker into acme, so solo has nobody left.
		client.workingDirs["worker"] = "acme/worker"
		await viewModel.stopStack()

		#expect(viewModel.selectedProject == "acme")
		#expect(viewModel.selection == nil)

		client.finishStream()
		await session.value
	}

	@Test("sends nothing when a process arrives while the action is reading")
	func abandonsAnActionWhenAProcessArrivesMidRead() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "extra": "acme/extra"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		client.hold(["api", "extra"])
		let bulk = Task { await viewModel.stopProject("acme") }
		await settle(until: { viewModel.isChangingStack })

		client.emit(.init(
			state: .init(name: "extra", namespace: "api", status: .running, isRunning: true)
		))
		await settle(until: { viewModel.processes.count == 2 })

		// The action's own read goes through, but the newcomer is still being placed.
		client.hold(["extra"])
		await bulk.value

		#expect(client.stopped.isEmpty)

		// The newcomer is placed afterwards, and the refusal still stands.
		client.hold([])
		await settle(until: { viewModel.isGroupingComplete })

		#expect(viewModel.lastError == "The stack changed while it was being read, so nothing was changed")

		client.finishStream()
		await session.value
	}

	@Test("does not ask when the dependency it needs is already up")
	func doesNotAskAboutADependencyAlreadyRunning() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed, isRunning: false),
			.init(name: "db", namespace: "ai", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "db": "chatbot-ai/app"]
		client.dependencies = ["api": ["db"]]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		viewModel.requestStartProject("acme")
		await settle(until: { client.started == ["api"] })

		#expect(viewModel.confirmation == nil)
		#expect(client.started == ["api"])

		client.finishStream()
		await session.value
	}

	@Test("starts a project outright when nothing it depends on lies outside it")
	func startsWithoutAskingWhenSelfContained() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed, isRunning: false),
			.init(name: "worker", namespace: "api", status: .completed, isRunning: false),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		client.dependencies = ["api": ["worker"]]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		viewModel.requestStartProject("acme")
		await settle(until: { client.started.count == 2 })

		#expect(viewModel.confirmation == nil)
		#expect(client.started.sorted() == ["api", "worker"])

		client.finishStream()
		await session.value
	}

	@Test("withholds a project action while one of its processes is already busy")
	func withholdsProjectActionWhileAProcessIsBusy() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		client.holdActions = true
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		#expect(viewModel.canStopProject("acme"))

		let single = Task { await viewModel.stopProcess("api") }
		await settle(until: { viewModel.isBusy("api") })

		#expect(!viewModel.canStopProject("acme"))
		#expect(!viewModel.canStartProject("acme"))

		client.holdActions = false
		await single.value
		client.finishStream()
		await session.value
	}

	@Test("withholds the stack power while one process is still answering")
	func withholdsStackPowerWhileAProcessIsBusy() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		client.holdActions = true
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		#expect(viewModel.canChangePower)

		let single = Task { await viewModel.stopProcess("api") }
		await settle(until: { viewModel.isBusy("api") })

		#expect(!viewModel.canChangePower)

		client.holdActions = false
		await single.value
		client.finishStream()
		await session.value
	}

	@Test("withholds a project start while a dependency in another project is busy")
	func withholdsProjectStartWhileADependencyIsBusy() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed, isRunning: false),
			.init(name: "db", namespace: "ai", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "db": "chatbot-ai/app"]
		client.dependencies = ["api": ["db"]]
		client.holdActions = true
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)
		#expect(viewModel.canStartProject("acme"))

		let single = Task { await viewModel.stopProcess("db") }
		await settle(until: { viewModel.isBusy("db") })

		#expect(!viewModel.canStartProject("acme"))

		client.holdActions = false
		await single.value
		client.finishStream()
		await session.value
	}

	@Test("refuses a single process's action while a stack action is still running")
	func refusesARowActionDuringAStackAction() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		client.holdActions = true
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		let group = Task { await viewModel.stopStack() }
		await settle(until: { client.stopped == ["worker"] })

		// A process the group has not reached yet, so the refusal is the group action's
		// doing rather than that one process already being busy.
		await viewModel.stopProcess("api")

		#expect(client.stopped == ["worker"])

		client.holdActions = false
		await group.value
		client.finishStream()
		await session.value
	}

	@Test("refuses a stack action while one process is still answering")
	func refusesAStackActionDuringARowAction() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		client.holdActions = true
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		let single = Task { await viewModel.stopProcess("api") }
		await settle(until: { viewModel.isBusy("api") })

		await viewModel.stopStack()

		#expect(client.stopped == ["api"])
		#expect(viewModel.lastError == "Did not stop the stack, because what it could do changed")

		client.holdActions = false
		await single.value
		client.finishStream()
		await session.value
	}

	@Test("stops saying the grouping is short once every configuration answers")
	func clearsTheGroupingErrorOnRecovery() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		client.refusingConfigurations = ["worker"]
		let viewModel = StackViewModel(client: client)

		let first = Task { await viewModel.observe() }
		await settle(viewModel)
		#expect(viewModel.lastError != nil)
		client.finishStream()
		await first.value

		client.refusingConfigurations = []
		await viewModel.observe()

		#expect(viewModel.isGroupingComplete)
		#expect(viewModel.lastError == nil)
	}

	@Test("stops nothing in a project it cannot account for, even when asked directly")
	func refusesAProjectStopWhileGroupingIsIncomplete() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		client.refusingConfigurations = ["worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		await viewModel.stopProject("acme")

		#expect(client.stopped.isEmpty)
		#expect(viewModel.lastError == "Did not stop acme, because what it could do changed")

		client.finishStream()
		await session.value
	}

	@Test("offers project actions once every process is accounted for")
	func offersProjectActionsWhenGroupingIsComplete() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "worker", namespace: "api", status: .completed, isRunning: false),
		])
		client.workingDirs = ["api": "acme/api", "worker": "acme/worker"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		#expect(viewModel.isGroupingComplete)
		#expect(viewModel.canStopProject("acme"))
		#expect(viewModel.canStartProject("acme"))
		#expect(viewModel.lastError == nil)

		client.finishStream()
		await session.value
	}

	@Test("offers no project actions once the server is gone")
	func offersNoProjectActionsWhileDisconnected() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "chatbot", namespace: "ai", status: .completed, isRunning: false),
		])
		client.workingDirs = ["api": "acme/api", "chatbot": "acme-ai-chatbot"]
		let viewModel = StackViewModel(client: client)
		client.finishStream()

		await viewModel.observe()

		#expect(!viewModel.canStopProject("acme"))
		#expect(!viewModel.canStartProject("acme-ai-chatbot"))
	}

	@Test("names every running process when asked to stop the server")
	func asksAboutTheServerAndItsProcesses() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .running, isRunning: true),
			.init(name: "web", namespace: "web", status: .running, isRunning: true),
		])
		client.workingDirs = ["api": "acme/api", "web": "other/web"]
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		#expect(viewModel.question(for: .stopServer(identity: 0)) == "Stop the server and 2 running processes?")

		client.finishStream()
		await session.value
	}

	@Test("does not promise the server is idle when it has no list of what it runs")
	func asksConservativelyAboutAServerItCannotSee() async {
		let client = StubClient(loadFailure: ProcessComposeError.unreachable(port: 28080))
		let viewModel = StackViewModel(client: client)

		await viewModel.observe()

		#expect(viewModel.question(for: .stopServer(identity: 0)) == "Stop the server and every process it is running?")
	}

	@Test("asks about the server alone when nothing is running")
	func asksAboutTheServerAlone() async {
		let client = StubClient(processes: [
			.init(name: "api", namespace: "api", status: .completed, isRunning: false),
		])
		let viewModel = StackViewModel(client: client)

		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		#expect(viewModel.question(for: .stopServer(identity: 0)) == "Stop the server?")

		client.finishStream()
		await session.value
	}

	@Test("offers nothing when no processes are known")
	func offersNothingWhenDisconnected() async {
		let client = StubClient(loadFailure: ProcessComposeError.unreachable(port: 28080))
		let viewModel = StackViewModel(client: client)

		await viewModel.observe()

		#expect(viewModel.power == .unavailable)
	}

	@Test("lists the config's projects, every process stopped, while no server answers")
	func listsTheDefinitionWhileOffline() async {
		let viewModel = StackViewModel(client: unreachable(), readDefinition: { _ in acmeDefinition })
		viewModel.define(from: localPlan)

		await viewModel.observe()

		#expect(viewModel.isShowingDefinition)
		#expect(viewModel.projects.map(\.name) == ["acme", "chatbot"])
		#expect(viewModel.processes.map(\.status) == [.stopped, .disabled, .stopped])
		#expect(viewModel.runningCount == 0)
	}

	@Test("shows the config once the server it was following goes away")
	func showsTheDefinitionAfterTheServerGoes() async {
		let client = StubClient(processes: [
			.init(name: "web", namespace: "acme", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: client, readDefinition: { _ in acmeDefinition })
		viewModel.define(from: localPlan)

		client.finishStream()
		await viewModel.observe()

		#expect(viewModel.isShowingDefinition)
		#expect(viewModel.processes.first { $0.name == "web" }?.status == .stopped)
	}

	@Test("follows the server once it answers, in place of the config")
	func replacesTheDefinitionWithTheServer() async {
		let viewModel = StackViewModel(client: unreachable(), readDefinition: { _ in acmeDefinition })
		viewModel.define(from: localPlan)
		await viewModel.observe()
		let client = StubClient(processes: [
			.init(name: "web", namespace: "acme", status: .running, isRunning: true),
		])
		client.workingDirs["web"] = "acme/web"
		viewModel.use(client)

		await settle(viewModel)

		#expect(!viewModel.isShowingDefinition)
		#expect(viewModel.processes.map(\.name) == ["web"])
		#expect(viewModel.processes.first?.status == .running)
	}

	@Test("follows the server that answers even when the config is read again while it loads")
	func keepsTheServerOverAConfigReadMidLoad() async {
		let client = StubClient(processes: [
			.init(name: "web", namespace: "acme", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: unreachable(), readDefinition: { _ in acmeDefinition })
		viewModel.define(from: localPlan)
		await viewModel.observe()
		client.beforeProjectState = { await viewModel.refreshDefinition() }
		viewModel.use(client)

		await settle(viewModel)

		#expect(!viewModel.isShowingDefinition)
		#expect(viewModel.processes.first?.status == .running)
	}

	@Test("keeps the project chosen before launch when the config defines it")
	func keepsTheRestoredProjectOffline() async {
		let viewModel = StackViewModel(client: unreachable(), readDefinition: { _ in acmeDefinition })
		viewModel.select(project: "chatbot")
		viewModel.define(from: localPlan)

		await viewModel.observe()

		#expect(viewModel.selectedProject == "chatbot")
		#expect(viewModel.visibleProcesses.map(\.name) == ["bot"])
	}

	@Test("lists the new config once Settings points the app at another stack")
	func showsTheNewDefinitionAfterMoving() async {
		let relay = [DefinedProcess(name: "relay", configuration: .init(workingDir: "relay"))]
		let viewModel = StackViewModel(client: unreachable(), readDefinition: { plan in
			plan.port == 28181 ? relay : acmeDefinition
		})
		viewModel.define(from: localPlan)
		await viewModel.observe()

		viewModel.use(unreachable())
		viewModel.define(from: ServerLaunchPlan(executablePath: "/bin/pc", configurationPath: "/relay.yaml", port: 28181))
		await settle(until: { viewModel.isShowingDefinition })

		#expect(viewModel.processes.map(\.name) == ["relay"])
		#expect(viewModel.projects.map(\.name) == ["relay"])
	}

	@Test("lists nothing for a server on another machine, whose config the app does not start")
	func listsNothingForARemoteServer() async {
		let viewModel = StackViewModel(client: unreachable(), readDefinition: { _ in acmeDefinition })
		viewModel.define(
			from: ServerLaunchPlan(
				executablePath: "/bin/pc",
				configurationPath: "/stack/process-compose.yaml",
				host: "build.example",
				port: 28080
			)
		)

		await viewModel.observe()

		#expect(!viewModel.isShowingDefinition)
		#expect(viewModel.processes.isEmpty)
	}

	@Test("offers no start or stop on a process the config describes")
	func offersNoRowActionsOffline() async {
		let viewModel = StackViewModel(client: unreachable(), readDefinition: { _ in acmeDefinition })
		viewModel.define(from: localPlan)

		await viewModel.observe()

		#expect(!viewModel.canStart("web"))
		#expect(!viewModel.canStop("web"))
	}

	@Test("says why the config could not be read, and stops listing it")
	func reportsAConfigItCanNoLongerRead() async {
		var isBroken = false
		let viewModel = StackViewModel(client: unreachable(), readDefinition: { _ in
			guard !isBroken else { throw StackDefinitionError.unclosedExpansion }
			return acmeDefinition
		})
		viewModel.define(from: localPlan)
		await viewModel.observe()
		isBroken = true

		viewModel.refreshDefinition()

		#expect(viewModel.definitionProblem == "Could not read process-compose.yaml: a ${ is never closed")
		#expect(!viewModel.isShowingDefinition)
		#expect(viewModel.processes.isEmpty)
	}

	@Test("shows a config read while the server is still answering only once it goes")
	func holdsTheDefinitionWhileConnected() async {
		let client = StubClient(processes: [
			.init(name: "web", namespace: "acme", status: .running, isRunning: true),
		])
		let viewModel = StackViewModel(client: client, readDefinition: { _ in acmeDefinition })
		let session = Task { await viewModel.observe() }
		await settle(viewModel)

		viewModel.define(from: localPlan)

		#expect(!viewModel.isShowingDefinition)
		#expect(viewModel.processes.first?.status == .running)

		client.finishStream()
		await session.value
	}

	private func unreachable() -> StubClient {
		StubClient(loadFailure: ProcessComposeError.unreachable(port: 28080))
	}

	private var localPlan: ServerLaunchPlan {
		ServerLaunchPlan(executablePath: "/bin/pc", configurationPath: "/stack/process-compose.yaml", port: 28080)!
	}

	private var acmeDefinition: [DefinedProcess] {
		[
			DefinedProcess(name: "web", namespace: "acme", configuration: .init(workingDir: "acme/web")),
			DefinedProcess(
				name: "worker",
				namespace: "acme",
				isDisabled: true,
				configuration: .init(workingDir: "acme/worker")
			),
			DefinedProcess(name: "bot", namespace: "chatbot", configuration: .init(workingDir: "chatbot/bot")),
		]
	}
}

struct ProcessStateTests {
	@Test("a process that exited with an error code reads as failed")
	func errorExitIsFailure() {
		let state = ProcessState(name: "migrate", status: .completed, exitCode: 1)

		#expect(state.indicator == .failed)
	}

	@Test("a process stopped by a signal reads as idle, not failed")
	func signalledStopIsIdle() {
		let state = ProcessState(name: "worker", status: .completed, exitCode: -1)

		#expect(state.indicator == .idle)
	}

	@Test("a clean one-shot reads as idle, not failed")
	func cleanExitIsIdle() {
		let state = ProcessState(name: "acme-docker", status: .completed, exitCode: 0)

		#expect(state.indicator == .idle)
	}

	@Test("speaks a running service as one sentence with its readiness and usage")
	func speaksARunningService() {
		let state = ProcessState(
			name: "api",
			status: .running,
			readiness: "Ready",
			hasReadinessProbe: true,
			memoryBytes: 140_000_000,
			cpuPercent: 3.5,
			isRunning: true,
			ageNanoseconds: 61_000_000_000
		)

		let summary = state.spokenSummary(kind: .service)

		let usage = "up \(Duration.seconds(61).compactLabel), 3.5% processor, \(ResourceFormat.memory(140_000_000)) memory"
		#expect(summary == "api, service, Running, ready, \(usage)")
	}

	@Test("speaks a failed task's exit code and what set it off")
	func speaksAFailedTask() {
		let state = ProcessState(
			name: "migrate",
			status: .completed,
			exitCode: 1,
			isWatched: true,
			watchTriggerPath: "db/schema.sql"
		)

		let summary = state.spokenSummary(kind: .task)

		#expect(summary == "migrate, task, Completed, file watcher armed, triggered by db/schema.sql, exit code 1")
	}

	@Test("leaves a stopped service's signal exit unspoken")
	func leavesASignalledStopUnspoken() {
		let state = ProcessState(name: "worker", status: .completed, restarts: 2, exitCode: -1)

		let summary = state.spokenSummary(kind: .service)

		#expect(summary == "worker, service, Completed, 2 restarts")
	}

	@Test("a running process with an unsatisfied probe still reads as waiting")
	func unreadyProbeIsWaiting() {
		let state = ProcessState(
			name: "chatbot",
			status: .running,
			readiness: "Not Ready",
			hasReadinessProbe: true,
			isRunning: true
		)

		#expect(state.indicator == .waiting)
	}

	@Test("a disabled process offers start and not stop")
	func disabledProcessCanOnlyStart() {
		let state = ProcessState(name: "relay", status: .disabled)

		#expect(state.canStart)
		#expect(!state.canStop)
	}

	@Test("counts a process the server calls Running as running, whatever the flag says")
	func trustsTheStatusOverTheRunningFlag() throws {
		let json = """
		{"name":"beta","namespace":"default","status":"Running","is_running":false}
		""".data(using: .utf8)!

		let state = try JSONDecoder().decode(ProcessState.self, from: json)

		#expect(state.isRunning)
		#expect(state.canStop)
	}

	@Test("decodes the server's process payload")
	func decodesServerPayload() throws {
		let json = """
		{"name":"api","namespace":"api","status":"Running","is_ready":"Ready",
		"has_ready_probe":true,"restarts":0,"exit_code":0,"pid":69794,
		"mem":34226176,"cpu":0.5,"is_running":true,"age":194399630583}
		""".data(using: .utf8)!

		let state = try JSONDecoder().decode(ProcessState.self, from: json)

		#expect(state.name == "api")
		#expect(state.status == .running)
		#expect(state.isReady)
		#expect(state.age == .nanoseconds(194_399_630_583))
	}
}

final class StubClient: ProcessComposeClient, @unchecked Sendable {
	nonisolated(unsafe) var actionFailure: (any Error)?
	nonisolated(unsafe) var refusingProcesses: Set<String> = []
	nonisolated(unsafe) var started: [String] = []
	nonisolated(unsafe) var stopped: [String] = []

	nonisolated(unsafe) var workingDirs: [String: String] = [:]
	nonisolated(unsafe) var dependencies: [String: [String]] = [:]
	nonisolated(unsafe) var logStreamFailure: (any Error)?
	nonisolated(unsafe) var truncated: [String] = []

	private let loadResult: Result<[ProcessState], any Error>
	private let stream: AsyncThrowingStream<ProcessStateEvent, any Error>
	private let continuation: AsyncThrowingStream<ProcessStateEvent, any Error>.Continuation
	private let logStream: AsyncThrowingStream<LogMessage, any Error>
	private let logContinuation: AsyncThrowingStream<LogMessage, any Error>.Continuation

	init(processes: [ProcessState] = [], loadFailure: (any Error)? = nil) {
		loadResult = loadFailure.map { .failure($0) } ?? .success(processes)
		(stream, continuation) = AsyncThrowingStream.makeStream()
		(logStream, logContinuation) = AsyncThrowingStream.makeStream()
	}

	func emit(_ event: ProcessStateEvent) { continuation.yield(event) }
	func finishStream() { continuation.finish() }

	func processes() async throws -> [ProcessState] { try loadResult.get() }

	nonisolated(unsafe) var refusingConfigurations: Set<String> = []
	/// Names whose first configuration request fails and whose second succeeds.
	nonisolated(unsafe) var refusingConfigurationsOnce: Set<String> = []

	private let configurationLock = NSLock()
	nonisolated(unsafe) private var refusedOnce: Set<String> = []
	nonisolated(unsafe) private var heldConfigurations: Set<String> = []

	/// Holds a configuration request open, so a test can see what happens meanwhile.
	func hold(_ names: Set<String>) {
		configurationLock.withLock { heldConfigurations = names }
	}

	func configuration(for name: String) async throws -> ProcessConfiguration {
		guard !refusingConfigurations.contains(name) else {
			throw ProcessComposeError.unreachable(port: 28080)
		}

		while configurationLock.withLock({ heldConfigurations.contains(name) }) {
			try? await Task.sleep(for: .milliseconds(5))
		}

		let refusingNow = configurationLock.withLock {
			refusingConfigurationsOnce.contains(name) && refusedOnce.insert(name).inserted
		}

		guard !refusingNow else { throw ProcessComposeError.unreachable(port: 28080) }

		return ProcessConfiguration(workingDir: workingDirs[name], dependsOn: dependencies[name] ?? [])
	}

	/// Lets a test hold a connection inside its setup phase.
	nonisolated(unsafe) var beforeProjectState: (() async -> Void)?

	func projectState() async throws -> ProjectState {
		await beforeProjectState?()

		return ProjectState(
			projectName: "test",
			version: "v1.122.0",
			processNum: 0,
			runningProcessNum: 0,
			upTimeNanoseconds: 0,
			configFiles: ["/tmp/process-compose.yaml"]
		)
	}

	func start(_ name: String) async throws {
		started.append(name)
		try failIfConfigured(name)
	}

	nonisolated(unsafe) private var holdingActions = false

	/// Keeps a process action in flight, so a test can look at the model while it is busy.
	var holdActions: Bool {
		get { configurationLock.withLock { holdingActions } }
		set { configurationLock.withLock { holdingActions = newValue } }
	}

	func stop(_ name: String) async throws {
		stopped.append(name)

		while holdActions {
			try? await Task.sleep(for: .milliseconds(5))
		}

		try failIfConfigured(name)
	}

	func restart(_ name: String) async throws { try failIfConfigured() }

	func stateEvents() -> AsyncThrowingStream<ProcessStateEvent, any Error> { stream }

	func logMessages(for name: String, backfill: Int) -> AsyncThrowingStream<LogMessage, any Error> {
		if let logStreamFailure {
			return AsyncThrowingStream { $0.finish(throwing: logStreamFailure) }
		}
		return logStream
	}

	func truncateLogs(for name: String) async throws {
		truncated.append(name)
		try failIfConfigured()
	}

	func emitLog(_ message: LogMessage) { logContinuation.yield(message) }
	func finishLogStream() { logContinuation.finish() }

	private func failIfConfigured(_ name: String? = nil) throws {
		if let name, refusingProcesses.contains(name) {
			throw ProcessComposeError.server(message: "no such process: \(name)")
		}
		if let actionFailure { throw actionFailure }
	}
}
