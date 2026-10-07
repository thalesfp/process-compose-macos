import AppKit
import SwiftUI

/// Hands the stack window to the quit coordinator and routes its close through quitting.
/// SwiftUI on macOS 14 has no way to veto closing a window, so this answers the window's
/// delegate for that one question and passes every other one to the delegate SwiftUI set.
struct StackWindowHook: NSViewRepresentable {
	let quit: QuitCoordinator

	func makeNSView(context: Context) -> HookView {
		HookView(quit: quit)
	}

	func updateNSView(_ view: HookView, context: Context) {}

	final class HookView: NSView {
		private let quit: QuitCoordinator
		private var proxy: CloseProxy?

		init(quit: QuitCoordinator) {
			self.quit = quit
			super.init(frame: .zero)
		}

		@available(*, unavailable)
		required init?(coder: NSCoder) {
			fatalError("HookView is only made in code")
		}

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()

			guard let window, !(window.delegate is CloseProxy) else { return }

			let proxy = CloseProxy(original: window.delegate) { [weak quit] in quit?.closeRequested() }
			window.delegate = proxy
			self.proxy = proxy
			quit.attach(window)
		}
	}
}

/// Answers `windowShouldClose` and forwards everything else to the delegate it replaced.
final class CloseProxy: NSObject, NSWindowDelegate {
	private let original: (any NSWindowDelegate)?
	private let onClose: () -> Void

	init(original: (any NSWindowDelegate)?, onClose: @escaping () -> Void) {
		self.original = original
		self.onClose = onClose
	}

	override func responds(to selector: Selector!) -> Bool {
		super.responds(to: selector) || (original?.responds(to: selector) ?? false)
	}

	override func forwardingTarget(for selector: Selector!) -> Any? {
		original?.responds(to: selector) == true ? original : nil
	}

	func windowShouldClose(_ sender: NSWindow) -> Bool {
		onClose()
		return false
	}
}
