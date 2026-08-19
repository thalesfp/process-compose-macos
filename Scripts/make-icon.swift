import AppKit

// Draws the app icon at every size macOS asks for, then hands the folder to iconutil.
func drawIcon(size: CGFloat) -> NSImage {
	let image = NSImage(size: NSSize(width: size, height: size))
	image.lockFocus()

	let unit = size / 1024
	let bounds = NSRect(x: 0, y: 0, width: size, height: size)

	let background = NSBezierPath(roundedRect: bounds, xRadius: 225 * unit, yRadius: 225 * unit)
	NSGradient(
		starting: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.17, alpha: 1),
		ending: NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.09, alpha: 1)
	)?.draw(in: background, angle: -90)

	let bars: [(width: CGFloat, color: NSColor)] = [
		(560, NSColor.systemGreen),
		(400, NSColor.systemMint),
		(620, NSColor.systemOrange),
		(300, NSColor.systemGray),
	]

	let barHeight = 92 * unit
	let spacing = 60 * unit
	let left = 190 * unit
	var top = size - 300 * unit

	for bar in bars {
		let dot = NSBezierPath(ovalIn: NSRect(
			x: left - 100 * unit,
			y: top,
			width: barHeight,
			height: barHeight
		))
		bar.color.setFill()
		dot.fill()

		let rail = NSBezierPath(roundedRect: NSRect(
			x: left + 60 * unit,
			y: top + barHeight * 0.22,
			width: bar.width * unit,
			height: barHeight * 0.56
		), xRadius: barHeight * 0.28, yRadius: barHeight * 0.28)
		bar.color.withAlphaComponent(0.45).setFill()
		rail.fill()

		top -= barHeight + spacing
	}

	image.unlockFocus()
	return image
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
	let pixels = CGFloat(base * scale)
	let image = drawIcon(size: pixels)

	guard
		let tiff = image.tiffRepresentation,
		let rep = NSBitmapImageRep(data: tiff),
		let png = rep.representation(using: .png, properties: [:])
	else { continue }

	let suffix = scale == 2 ? "@2x" : ""
	try png.write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
}
