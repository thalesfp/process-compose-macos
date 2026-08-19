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

		if !coordinator.matches(fontSize: fontSize) {
			coordinator.reset(storage, size: fontSize)
		}

		let plan = LogRendering.plan(rendered: coordinator.renderedIDs, lines: lines)

		if !plan.isEmpty {
			storage.beginEditing()
			coordinator.drop(plan.dropLeading, from: storage)
			coordinator.append(plan.append, to: storage)
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
		var wasFollowing = true

		private var rendered: [(id: Int, length: Int)] = []
		private var fonts: (size: Double, plain: NSFont, strong: NSFont)?

		var renderedIDs: [Int] { rendered.map(\.id) }

		func matches(fontSize: Double) -> Bool {
			fonts?.size == fontSize
		}

		func reset(_ storage: NSTextStorage, size: Double) {
			storage.setAttributedString(NSAttributedString())
			rendered = []
			fonts = (
				size,
				NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
				NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
			)
		}

		func drop(_ count: Int, from storage: NSTextStorage) {
			guard count > 0 else { return }

			let length = rendered.prefix(count).reduce(0) { $0 + $1.length }
			storage.deleteCharacters(in: NSRange(location: 0, length: length))
			rendered.removeFirst(count)
		}

		/// One `append` for the whole batch: a 300-line backfill would otherwise be 300
		/// separate text-storage mutations, each triggering its own layout pass.
		func append(_ lines: [LogLine], to storage: NSTextStorage) {
			guard let fonts else { return }

			let batch = NSMutableAttributedString()

			for line in lines {
				let start = batch.length
				draw(line, into: batch, fonts: fonts)
				rendered.append((line.id, batch.length - start))
			}

			storage.append(batch)
		}

		private func draw(
			_ line: LogLine,
			into batch: NSMutableAttributedString,
			fonts: (size: Double, plain: NSFont, strong: NSFont)
		) {
			for span in line.spans {
				batch.append(
					NSAttributedString(
						string: span.text,
						attributes: [
							.font: span.isBold ? fonts.strong : fonts.plain,
							.foregroundColor: span.color?.nsColor ?? NSColor.labelColor,
						]
					)
				)
			}

			batch.append(NSAttributedString(string: "\n", attributes: [.font: fonts.plain]))
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
