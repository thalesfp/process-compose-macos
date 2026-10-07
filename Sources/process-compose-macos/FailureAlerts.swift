import AppKit
import Observation
import os
import ProcessComposeCore
import UserNotifications

/// Tells the user about failures they were not there to see: a count on the Dock icon and
/// one notification per batch, which selects the process when clicked.
@MainActor
final class FailureAlerts: NSObject, UNUserNotificationCenterDelegate {
	private nonisolated static let processKey = "process"

	private let model: StackViewModel
	private let logger = Logger(subsystem: "me.thales.process-compose", category: "FailureAlerts")
	private var failures = UnseenFailures()

	init(model: StackViewModel) {
		self.model = model
		super.init()

		notificationCenter?.delegate = self
		watch()
	}

	/// The user came back to the app.
	func acknowledge() {
		failures.acknowledge()
		showBadge()
	}

	// UNUserNotificationCenter raises for a process without a bundle identifier, which is how `swift run` launches.
	private var notificationCenter: UNUserNotificationCenter? {
		Bundle.main.bundleIdentifier == nil ? nil : .current()
	}

	private func watch() {
		withObservationTracking {
			_ = model.processes
		} onChange: { [weak self] in
			Task { @MainActor in
				self?.refresh()
				self?.watch()
			}
		}
	}

	private func refresh() {
		let news = failures.observe(model.processes, isActive: NSApp.isActive)

		showBadge()

		guard !news.isEmpty else { return }

		announce(news)
	}

	private func showBadge() {
		NSApp.dockTile.badgeLabel = failures.names.isEmpty ? nil : String(failures.names.count)
	}

	private func announce(_ failed: [ProcessState]) {
		guard let center = notificationCenter, let first = failed.first else { return }

		let content = UNMutableNotificationContent()
		content.title = FailureAnnouncement.title(for: failed)
		content.body = FailureAnnouncement.body(for: failed)
		content.sound = .default
		content.userInfo = [Self.processKey: first.name]

		let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

		Task {
			do {
				guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }

				try await center.add(request)
			} catch {
				logger.error("Could not post a failure notification, and the Dock badge still counts it: \(error.localizedDescription)")
			}
		}
	}

	nonisolated func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		didReceive response: UNNotificationResponse
	) async {
		let name = response.notification.request.content.userInfo[Self.processKey] as? String

		await MainActor.run {
			NSApp.activate()
			name.map(model.reveal)
		}
	}
}
