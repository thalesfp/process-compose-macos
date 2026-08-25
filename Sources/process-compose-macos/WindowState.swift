import Observation

/// The flags the window and the menu bar both act on. A SwiftUI `Commands` body sits
/// outside the view tree, so a menu item cannot reach a view's `@State`.
@MainActor
@Observable
final class WindowState {
	var isShowingServerLog = false
	var isSettingUpServer = false
	var isConfirmingStopServer = false
}
