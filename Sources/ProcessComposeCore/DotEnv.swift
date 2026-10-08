/// The env files process-compose v1.122.0 reads, `.env` and `.pc_env`, go through godotenv,
/// which takes `NAME=value`, `export NAME=value` and `NAME: value`.
enum DotEnv {
	static func values(in text: String) -> [String: String] {
		var values: [String: String] = [:]

		for line in text.split(whereSeparator: \.isNewline) {
			guard let (name, value) = assignment(in: line) else { continue }

			values[name] = value
		}

		return values
	}

	private static func assignment(in line: Substring) -> (name: String, value: String)? {
		var rest = line.trimmingPrefix(while: \.isWhitespace)

		if rest.hasPrefix("#") { return nil }
		if rest.hasPrefix("export ") { rest = rest.dropFirst("export ".count) }

		guard let separator = rest.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return nil }

		let name = rest[..<separator].trimmingCharacters(in: .whitespaces)
		let value = rest[rest.index(after: separator)...].trimmingCharacters(in: .whitespaces)

		return (name, unquoted(value))
	}

	private static func unquoted(_ value: String) -> String {
		let opensWithQuote = value.hasPrefix("\"") || value.hasPrefix("'")
		let isQuoted = value.count >= 2 && opensWithQuote && value.first == value.last

		guard isQuoted else { return value.components(separatedBy: " #").first ?? value }

		return String(value.dropFirst().dropLast())
	}
}
