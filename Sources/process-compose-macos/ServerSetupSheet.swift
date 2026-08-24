import ProcessComposeCore
import SwiftUI

/// Walks the three answers the app needs before it can start a server: which config,
/// where to run it, and whether process-compose accepts it.
struct ServerSetupSheet: View {
	@AppStorage(PreferenceKey.serverBinaryPath) private var binaryPath = PreferenceDefault.serverBinaryPath
	@AppStorage(PreferenceKey.serverConfigPath) private var configPath = PreferenceDefault.serverConfigPath
	@AppStorage(PreferenceKey.serverWorkingDirectory) private var workingDirectory = PreferenceDefault.serverWorkingDirectory
	@AppStorage(PreferenceKey.port) private var port = PreferenceDefault.port
	@AppStorage(PreferenceKey.suggestedConfigPath) private var suggestedConfig = PreferenceDefault.suggestedConfigPath

	@Environment(\.dismiss) private var dismiss

	@State private var draftBinary = ""
	@State private var draftConfig = ""
	@State private var draftWorkingDirectory = ""
	@State private var validation: ServerValidation?
	@State private var isValidating = false

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			VStack(alignment: .leading, spacing: 4) {
				Text("Set up the server")
					.font(.headline)
				Text("The app runs process-compose with these and stops it again when it quits.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			Form {
				LabeledContent("process-compose") {
					choice(draftBinary, placeholder: "Not chosen") { chooseBinary() }
				}

				LabeledContent("Config") {
					choice(draftConfig, placeholder: "Not chosen") { chooseConfig() }
				}

				LabeledContent("Working directory") {
					choice(draftWorkingDirectory, placeholder: "The config's own folder") { chooseWorkingDirectory() }
				}

				LabeledContent("Check") {
					HStack(alignment: .firstTextBaseline, spacing: 10) {
						Button("Validate") { validate() }
							.disabled(plan == nil || isValidating)
						ValidationReadout(validation: validation)
						Spacer(minLength: 0)
					}
				}
			}
			.formStyle(.grouped)

			HStack {
				Text(saveHint)
					.font(.caption)
					.foregroundStyle(.secondary)

				Spacer(minLength: 12)

				Button("Cancel") { dismiss() }
					.keyboardShortcut(.cancelAction)

				Button("Save") { save() }
					.keyboardShortcut(.defaultAction)
					.disabled(validation != .valid)
			}
		}
		.padding(20)
		.frame(width: 560)
		.task {
			draftBinary = binaryPath
			// The server the app connected to said this was its config. Nothing is run from
			// it until it is checked and saved here, since anything can answer a port.
			draftConfig = configPath.isEmpty ? suggestedConfig : configPath
			draftWorkingDirectory = workingDirectory
		}
	}

	private func choice(_ path: String, placeholder: String, choose: @escaping () -> Void) -> some View {
		HStack(spacing: 8) {
			Text(path.isEmpty ? placeholder : path)
				.font(.callout)
				.foregroundStyle(path.isEmpty ? .secondary : .primary)
				.lineLimit(1)
				.truncationMode(.head)

			Spacer(minLength: 8)

			Button("Choose", action: choose)
		}
	}

	private var saveHint: String {
		switch validation {
		case .valid: "process-compose loads this config"
		case .failed: "Fix the config, or choose the directory its paths are relative to"
		case nil: "Validate the config to save it"
		}
	}

	private var plan: ServerLaunchPlan? {
		ServerLaunchPlan(
			executablePath: draftBinary,
			configurationPath: draftConfig,
			workingDirectoryPath: draftWorkingDirectory,
			host: PreferenceDefault.host,
			port: port
		)
	}

	private func chooseBinary() {
		guard let chosen = FilePicker.choose("The process-compose binary, or a script that runs it", startingAt: draftBinary) else { return }

		draftBinary = chosen
		validation = nil
	}

	private func chooseConfig() {
		guard let chosen = FilePicker.choose("Project config", startingAt: draftConfig) else { return }

		draftConfig = chosen
		validation = nil
	}

	private func chooseWorkingDirectory() {
		guard
			let chosen = FilePicker.choose(
				"Where process-compose runs",
				isDirectory: true,
				startingAt: draftWorkingDirectory.isEmpty ? draftConfig : draftWorkingDirectory
			)
		else { return }

		draftWorkingDirectory = chosen
		validation = nil
	}

	private func validate() {
		guard let checked = plan else { return }

		isValidating = true
		validation = nil

		Task {
			let answer = await LiveServerRunner().validate(checked)

			isValidating = false

			// The rows stay live while a check runs, and a verdict on what used to be there
			// must not be what Save is granted on.
			guard checked == plan else { return }

			validation = answer
		}
	}

	private func save() {
		binaryPath = draftBinary
		configPath = draftConfig
		workingDirectory = draftWorkingDirectory
		dismiss()
	}
}
