import Foundation
import Yams

/// A process as the config describes it, before any server runs it.
public struct DefinedProcess: Sendable, Hashable {
	public let name: String
	public let namespace: String
	public let isDisabled: Bool
	public let configuration: ProcessConfiguration

	public init(
		name: String,
		namespace: String = "default",
		isDisabled: Bool = false,
		configuration: ProcessConfiguration
	) {
		self.name = name
		self.namespace = namespace
		self.isDisabled = isDisabled
		self.configuration = configuration
	}

	public var stoppedState: ProcessState {
		ProcessState(name: name, namespace: namespace, status: isDisabled ? .disabled : .stopped)
	}
}

public enum StackDefinitionError: LocalizedError, Equatable {
	case extendsLoop(String)
	case unknownParent(process: String, parent: String)
	case processExtendsLoop(String)
	case unsupportedExpansion(String)
	case unclosedExpansion
	case invalidYAML(String)
	case wrongKind(path: String)

	public var errorDescription: String? {
		switch self {
		case .extendsLoop(let path): "\(path) is extended more than once"
		case .unknownParent(let process, let parent): "\(process) extends \(parent), which the config does not define"
		case .processExtendsLoop(let process): "\(process) extends itself, directly or through another process"
		case .unsupportedExpansion(let expression): "the app cannot expand \(expression)"
		case .unclosedExpansion: "a ${ is never closed"
		case .invalidYAML(let detail): "it is not valid YAML (\(detail))"
		case .wrongKind(let path): "\(path) is not the kind of value process-compose expects"
		}
	}
}

/// The processes a config defines, read the way process-compose v1.122.0 reads them for
/// `up -f`. Go templates and the server's strict validation are not reproduced.
public enum StackDefinition {
	public static func processes(
		for plan: ServerLaunchPlan,
		environment: [String: String],
		contents: (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }
	) throws -> [DefinedProcess] {
		let serverEnvironment = plan.environment(environment)
		// process-compose reads `.env` from where it runs and ignores one it cannot read.
		let dotenv = (try? contents(plan.workingDirectory.appendingPathComponent(".env"))).map(DotEnv.values) ?? [:]
		let lookup: (String) -> String = { dotenv[$0] ?? serverEnvironment[$0] ?? "" }

		let configuration = plan.configuration.standardizedFileURL
		let files = try chain(from: configuration, seen: [configuration.path]) {
			try parse(contents($0), lookup: lookup)
		}
		let merged = files.reduce(into: [String: ConfigProcess]()) { merged, processes in
			merged.merge(processes) { earlier, later in earlier.merged(with: later) }
		}

		return try defined(resolvingExtends(merged))
	}

	/// process-compose merges every file a config extends before it, after anchoring the
	/// extended file's processes to that file's directory.
	private static func chain(
		from url: URL,
		seen: [String],
		read: (URL) throws -> ConfigFile
	) throws -> [[String: ConfigProcess]] {
		let file = try read(url)
		let directory = url.deletingLastPathComponent().path
		let isExtended = seen.count > 1
		let processes = isExtended ? file.processes.mapValues { $0.anchored(at: directory) } : file.processes

		guard let extends = file.extends, !extends.isEmpty else { return [processes] }

		let parent = resolved(extends, in: directory)

		guard !seen.contains(parent.path) else { throw StackDefinitionError.extendsLoop(parent.path) }

		return try chain(from: parent, seen: seen + [parent.path], read: read) + [processes]
	}

	/// process-compose expands the text before parsing it, and with `disable_env_expansion`
	/// parses the raw text again over the expanded result.
	private static func parse(_ text: String, lookup: (String) -> String) throws -> ConfigFile {
		let decoder = YAMLDecoder()

		do {
			let expanded = try decoder.decode(ConfigFile.self, from: EnvironmentExpansion.expand(text, lookup: lookup))

			guard expanded.disablesExpansion else { return expanded }

			let raw = try decoder.decode(ConfigFile.self, from: text)

			return ConfigFile(
				processes: expanded.processes.merging(raw.processes) { _, raw in raw },
				extends: raw.extends ?? expanded.extends,
				disablesExpansion: true
			)
		} catch let error as DecodingError {
			throw explained(error)
		}
	}

	/// Yams reports every failure as a DecodingError whose own description names nothing in the file.
	private static func explained(_ error: DecodingError) -> StackDefinitionError {
		switch error {
		case .dataCorrupted(let context):
			switch context.underlyingError as? YamlError {
			case .scanner(_, let problem, let mark, _)?, .parser(_, let problem, let mark, _)?,
				.composer(_, let problem, let mark, _)?:
				return .invalidYAML("\(problem) on line \(mark.line)")
			default:
				return .invalidYAML(context.debugDescription)
			}
		case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context):
			return .wrongKind(path: context.codingPath.map(\.stringValue).joined(separator: "."))
		@unknown default:
			return .invalidYAML(String(describing: error))
		}
	}

	/// process-compose merges a process over a copy of the one it extends, chains included.
	private static func resolvingExtends(_ processes: [String: ConfigProcess]) throws -> [String: ConfigProcess] {
		var resolved: [String: ConfigProcess] = [:]

		func resolve(_ name: String, _ process: ConfigProcess, visiting: Set<String>) throws -> ConfigProcess {
			if let done = resolved[name] { return done }

			guard let parentName = process.extends, !parentName.isEmpty else {
				resolved[name] = process
				return process
			}
			guard parentName != name, !visiting.contains(parentName) else {
				throw StackDefinitionError.processExtendsLoop(name)
			}
			guard let parent = processes[parentName] else {
				throw StackDefinitionError.unknownParent(process: name, parent: parentName)
			}

			let merged = try resolve(parentName, parent, visiting: visiting.union([name])).merged(with: process)
			resolved[name] = merged
			return merged
		}

		for (name, process) in processes {
			_ = try resolve(name, process, visiting: [])
		}

		return resolved
	}

	private static func defined(_ processes: [String: ConfigProcess]) -> [DefinedProcess] {
		processes.flatMap { name, process in
			process.replicaNames(for: name).map { replica in
				DefinedProcess(
					name: replica,
					namespace: process.namespaces?.first { !$0.isEmpty } ?? "default",
					isDisabled: process.isDisabled,
					configuration: process.configuration
				)
			}
		}
	}

	static func resolved(_ path: String, in directory: String) -> URL {
		URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardizedFileURL
	}
}

struct ConfigFile {
	let processes: [String: ConfigProcess]
	let extends: String?
	let disablesExpansion: Bool
}

extension ConfigFile: Decodable {
	enum CodingKeys: String, CodingKey {
		case processes, extends
		case disablesExpansion = "disable_env_expansion"
	}

	init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		processes = try c.decodeIfPresent([String: ConfigProcess].self, forKey: .processes) ?? [:]
		extends = try c.decodeIfPresent(String.self, forKey: .extends)
		disablesExpansion = try c.decodeIfPresent(Bool.self, forKey: .disablesExpansion) ?? false
	}
}

/// The fields of a process that decide its row.
struct ConfigProcess: Decodable {
	var namespaces: [String]?
	var workingDir: String?
	var disabled: Bool?
	var disabledText: String?
	var replicas: Int?
	var dependsOn: [String: Unread]?
	var restart: String?
	var hasWatch: Bool
	var hasMCP: Bool
	var extends: String?

	private struct Availability: Decodable {
		let restart: String?
	}

	enum CodingKeys: String, CodingKey {
		case namespace, disabled, replicas, availability, watch, mcp, extends
		case workingDir = "working_dir"
		case disabledText = "is_disabled"
		case dependsOn = "depends_on"
	}

	init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)

		if let single = try? c.decode(String.self, forKey: .namespace) {
			namespaces = [single]
		} else {
			namespaces = try c.decodeIfPresent([String].self, forKey: .namespace)
		}

		workingDir = try c.decodeIfPresent(String.self, forKey: .workingDir)
		disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled)
		disabledText = try c.decodeIfPresent(String.self, forKey: .disabledText)
		replicas = try c.decodeIfPresent(Int.self, forKey: .replicas)
		dependsOn = try c.decodeIfPresent([String: Unread].self, forKey: .dependsOn)
		restart = try c.decodeIfPresent(Availability.self, forKey: .availability)?.restart
		hasWatch = try c.decodeIfPresent(Unread.self, forKey: .watch) != nil
		hasMCP = try c.decodeIfPresent(Unread.self, forKey: .mcp) != nil
		extends = try c.decodeIfPresent(String.self, forKey: .extends)
	}

	/// process-compose merges a process defined twice with mergo, which skips a later value
	/// that is Go's zero value, so `false`, `""` and `0` never undo an earlier setting.
	func merged(with later: ConfigProcess) -> ConfigProcess {
		var merged = self

		if later.namespaces?.contains(where: { !$0.isEmpty }) == true { merged.namespaces = later.namespaces }
		if later.workingDir?.isEmpty == false { merged.workingDir = later.workingDir }
		if later.disabled == true { merged.disabled = true }
		if later.disabledText?.isEmpty == false { merged.disabledText = later.disabledText }
		if let replicas = later.replicas, replicas != 0 { merged.replicas = replicas }
		if let dependsOn = later.dependsOn { merged.dependsOn = (self.dependsOn ?? [:]).merging(dependsOn) { $1 } }
		if later.restart?.isEmpty == false { merged.restart = later.restart }
		merged.hasWatch = hasWatch || later.hasWatch
		merged.hasMCP = hasMCP || later.hasMCP
		if later.extends?.isEmpty == false { merged.extends = later.extends }

		return merged
	}

	/// process-compose gives an extended file's processes that file's directory as their
	/// working directory, or joins a relative one onto it.
	func anchored(at directory: String) -> ConfigProcess {
		var anchored = self
		let given = workingDir ?? ""

		anchored.workingDir = given.isEmpty ? directory : StackDefinition.resolved(given, in: directory).path

		return anchored
	}

	/// process-compose lets `is_disabled` override `disabled`, and always disables a process with an `mcp` block.
	var isDisabled: Bool {
		switch disabledText {
		case "true": true
		case "false": hasMCP
		default: (disabled ?? false) || hasMCP
		}
	}

	var configuration: ProcessConfiguration {
		ProcessConfiguration(
			workingDir: workingDir,
			hasWatcher: hasWatch,
			restartsAutomatically: restart.map { !$0.isEmpty && $0 != "no" } ?? false,
			dependsOn: (dependsOn ?? [:]).keys.sorted()
		)
	}

	/// process-compose names replicas `<name>-<index>`, the index zero-padded to the width of the count.
	func replicaNames(for name: String) -> [String] {
		guard let count = replicas, count > 1 else { return [name] }

		let width = String(count).count

		return (0..<count).map { "\(name)-\(String(format: "%0\(width)ld", $0))" }
	}
}

/// The `${...}` substitution process-compose runs over a config's text (drone/envsubst):
/// bare `$NAME` stays as it is, `$$` is a literal `$`, and `\\` and `\/` lose their backslash.
enum EnvironmentExpansion {
	static func expand(_ text: String, lookup: (String) -> String) throws -> String {
		var result = ""
		var rest = Substring(text)

		while let first = rest.first {
			let isEscapedSlash = rest.hasPrefix("\\\\") || rest.hasPrefix("\\/")

			if rest.hasPrefix("$$") {
				result.append("$")
				rest = rest.dropFirst(2)
			} else if rest.hasPrefix("${") {
				guard let close = rest.firstIndex(of: "}") else { throw StackDefinitionError.unclosedExpansion }

				let expression = rest[rest.index(rest.startIndex, offsetBy: 2)..<close]
				result.append(try value(of: expression, lookup: lookup))
				rest = rest[rest.index(after: close)...]
			} else if isEscapedSlash {
				result.append(rest[rest.index(after: rest.startIndex)])
				rest = rest.dropFirst(2)
			} else {
				result.append(first)
				rest = rest.dropFirst()
			}
		}

		return result
	}

	/// Every default operator envsubst accepts means "this when the variable is empty".
	private static func value(of expression: Substring, lookup: (String) -> String) throws -> String {
		let name = expression.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
		let operation = expression.dropFirst(name.count)

		guard !name.isEmpty, !operation.contains("${") else {
			throw StackDefinitionError.unsupportedExpansion("${\(expression)}")
		}

		let found = lookup(String(name))

		if operation.isEmpty { return found }

		for marker in [":-", ":=", ":?", ":+", "="] where operation.hasPrefix(marker) {
			return found.isEmpty ? String(operation.dropFirst(marker.count)) : found
		}

		throw StackDefinitionError.unsupportedExpansion("${\(expression)}")
	}
}
