import AppKit
import ConductorCore
import SwiftUI

/// The log body. An `NSTextView` backs it so a selection can span lines, which a stack
/// of SwiftUI `Text` views cannot do.
struct LogTextView: NSViewRepresentable {
	let lines: [LogLine]
	let fontSize: Double
	let isFollowing: Bool

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	func makeNSView(context: Context) -> NSScrollView {
		let scrollView = NSTextView.scrollableTextView()
		scrollView.hasVerticalScroller = true
		scrollView.drawsBackground = true
		scrollView.backgroundColor = .textBackgroundColor

		guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

		textView.isEditable = false
		textView.isSelectable = true
		textView.drawsBackground = true
		textView.backgroundColor = .textBackgroundColor
		textView.textContainerInset = NSSize(width: 8, height: 6)
		textView.isAutomaticQuoteSubstitutionEnabled = false
		textView.isAutomaticDashSubstitutionEnabled = false
		textView.isAutomaticSpellingCorrectionEnabled = false
		textView.textContainer?.widthTracksTextView = true
		textView.setAccessibilityLabel("Process output")

		return scrollView
	}

	func updateNSView(_ scrollView: NSScrollView, context: Context) {
		guard let textView = scrollView.documentView as? NSTextView,
			let storage = textView.textStorage
		else { return }

		let coordinator = context.coordinator

		if coordinator.fontSize != fontSize {
			coordinator.fontSize = fontSize
			coordinator.reset(storage)
		}

		let plan = LogRendering.plan(rendered: coordinator.renderedIDs, lines: lines)

		if !plan.isEmpty {
			storage.beginEditing()
			coordinator.drop(plan.dropLeading, from: storage)
			coordinator.append(plan.append, to: storage, size: fontSize)
			storage.endEditing()
		}

		if isFollowing, !plan.isEmpty || !coordinator.wasFollowing {
			textView.scrollToEndOfDocument(nil)
		}

		coordinator.wasFollowing = isFollowing
	}

	/// Holds what is already drawn so an arriving line costs one append instead of a
	/// full redraw of the buffer.
	final class Coordinator {
		var fontSize: Double = 0
		var wasFollowing = true
		private(set) var renderedIDs: [Int] = []
		private var renderedLengths: [Int] = []

		func reset(_ storage: NSTextStorage) {
			storage.setAttributedString(NSAttributedString())
			renderedIDs = []
			renderedLengths = []
		}

		func drop(_ count: Int, from storage: NSTextStorage) {
			guard count > 0 else { return }

			let length = renderedLengths.prefix(count).reduce(0, +)
			storage.deleteCharacters(in: NSRange(location: 0, length: length))
			renderedIDs.removeFirst(count)
			renderedLengths.removeFirst(count)
		}

		func append(_ lines: [LogLine], to storage: NSTextStorage, size: Double) {
			for line in lines {
				let drawn = Self.attributed(line, size: size)
				storage.append(drawn)
				renderedIDs.append(line.id)
				renderedLengths.append(drawn.length)
			}
		}

		private static func attributed(_ line: LogLine, size: Double) -> NSAttributedString {
			let plain = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
			let strong = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
			let drawn = NSMutableAttributedString()

			for span in line.spans {
				drawn.append(
					NSAttributedString(
						string: span.text,
						attributes: [
							.font: span.isBold ? strong : plain,
							.foregroundColor: span.color?.nsColor ?? NSColor.labelColor,
						]
					)
				)
			}

			drawn.append(NSAttributedString(string: "\n", attributes: [.font: plain]))

			return drawn
		}
	}
}

extension AnsiColor {
	var nsColor: NSColor {
		switch self {
		case .black: .secondaryLabelColor
		case .red: .systemRed
		case .green: .systemGreen
		case .yellow: .systemYellow
		case .blue: .systemBlue
		case .magenta: .systemPurple
		case .cyan: .systemTeal
		case .white: .labelColor
		}
	}
}
