/// Reads process configurations from one server. The server answers for each process
/// separately, so this is where a fan-out and its one retry live, apart from whatever the
/// caller then does with what came back.
public enum ConfigurationReader {
	public static func configurations(
		for names: [String],
		from client: any ProcessComposeClient
	) async -> [String: ProcessConfiguration] {
		var loaded = await read(names, from: client)

		// Each configuration is a request of its own, so a single blip would otherwise keep
		// a process out of the grouping for the whole connection, with no second chance
		// until something else forces a reconnect.
		let unread = names.filter { loaded[$0] == nil }

		guard !unread.isEmpty else { return loaded }

		for (name, configuration) in await read(unread, from: client) {
			loaded[name] = configuration
		}

		return loaded
	}

	private static func read(
		_ names: [String],
		from client: any ProcessComposeClient
	) async -> [String: ProcessConfiguration] {
		await withTaskGroup(of: (String, ProcessConfiguration?).self) { group in
			for name in names {
				group.addTask {
					(name, try? await client.configuration(for: name))
				}
			}

			var configurations: [String: ProcessConfiguration] = [:]
			for await (name, configuration) in group {
				configurations[name] = configuration
			}
			return configurations
		}
	}
}
