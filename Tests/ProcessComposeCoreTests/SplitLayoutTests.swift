import Testing

@testable import ProcessComposeCore

struct SplitLayoutTests {
	@Test("gives each pane its share of the window")
	func splitsByFraction() {
		let height = SplitLayout.topHeight(fraction: 0.5, total: 1000, minTop: 180, minBottom: 140)

		#expect(height == 500)
	}

	@Test("keeps the top pane readable when the divider is dragged to the top")
	func holdsTopMinimum() {
		let height = SplitLayout.topHeight(fraction: 0.01, total: 1000, minTop: 180, minBottom: 140)

		#expect(height == 180)
	}

	@Test("keeps the bottom pane readable when the divider is dragged to the bottom")
	func holdsBottomMinimum() {
		let height = SplitLayout.topHeight(fraction: 0.99, total: 1000, minTop: 180, minBottom: 140)

		#expect(height == 860)
	}

	@Test("gives the bottom pane what is left when the window is too short for both")
	func survivesTinyWindow() {
		let height = SplitLayout.topHeight(fraction: 0.5, total: 200, minTop: 180, minBottom: 140)

		#expect(height == 180)
	}

	@Test("turns a drag into the fraction it should store")
	func storesDraggedFraction() {
		let fraction = SplitLayout.fraction(
			startFraction: 0.5,
			translation: 100,
			total: 1000,
			minTop: 180,
			minBottom: 140
		)

		#expect(fraction == 0.6)
	}

	@Test("clamps a drag that would squeeze a pane shut")
	func clampsOverdrag() {
		let fraction = SplitLayout.fraction(
			startFraction: 0.5,
			translation: -500,
			total: 1000,
			minTop: 180,
			minBottom: 140
		)

		#expect(fraction == 0.18)
	}

	@Test("moves the divider the way the menu item names")
	func stepsInBothDirections() {
		#expect(SplitLayout.stepped(0.6, by: SplitLayout.step) > 0.6)
		#expect(SplitLayout.stepped(0.6, by: -SplitLayout.step) < 0.6)
	}

	@Test("stops the divider at its range rather than drifting past it")
	func clampsSteppedFraction() {
		#expect(SplitLayout.stepped(0.84, by: SplitLayout.step) == SplitLayout.fractionRange.upperBound)
		#expect(SplitLayout.stepped(0.16, by: -SplitLayout.step) == SplitLayout.fractionRange.lowerBound)
		#expect(SplitLayout.stepped(5, by: SplitLayout.step) == SplitLayout.fractionRange.upperBound)
	}

	@Test("still steps a divider a drag left outside the menu's own range")
	func stepsFromOutsideTheRange() {
		let dragged = SplitLayout.fraction(
			startFraction: 0.5,
			translation: 860,
			total: 2000,
			minTop: 180,
			minBottom: 140
		)

		#expect(dragged > SplitLayout.fractionRange.upperBound)
		#expect(SplitLayout.canStep(dragged, by: SplitLayout.step))
		#expect(SplitLayout.stepped(dragged, by: SplitLayout.step) == SplitLayout.fractionRange.upperBound)
	}

	@Test("offers no step once the divider is at the end it would move towards")
	func refusesAStepThatWouldNotMove() {
		#expect(!SplitLayout.canStep(SplitLayout.fractionRange.upperBound, by: SplitLayout.step))
		#expect(!SplitLayout.canStep(SplitLayout.fractionRange.lowerBound, by: -SplitLayout.step))
		#expect(SplitLayout.canStep(SplitLayout.fractionRange.upperBound, by: -SplitLayout.step))
	}
}
