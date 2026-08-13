import AppKit
import ScreenCaptureKit

/*
Photographs the live wallpaper, for the catalog and the gallery.

    $ swiftc -O -o /tmp/capture-preview tools/capture-preview.swift
    $ /tmp/capture-preview docs/preview.jpg

`screencapture -l` is no use here: a window-id capture does not see the Metal and SceneKit
layers Puddle draws into, and comes back white. ScreenCaptureKit does see them, and capturing
the wallpaper window on its own means whatever is stacked on top of it — terminals, editors —
is not in the shot.

The wallpaper sits at desktop level and is the same size as the display. The frame is cropped
to 16:10 around the board, which is where the catalog and the gallery show it.
*/

// Without this, ScreenCaptureKit aborts in CGS_REQUIRE_INIT: it needs a connection to the
// window server, which only exists once an NSApplication has been made.
_ = NSApplication.shared

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "preview.jpg")

func fail(_ message: String) -> Never {
	FileHandle.standardError.write(Data("capture-preview: \(message)\n".utf8))
	exit(1)
}

let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

// The biggest Puddle window: the desktop one. The menu and any settings sheet are smaller.
guard
	let window = content.windows
		.filter({ $0.owningApplication?.applicationName == "Puddle" })
		.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
else {
	fail("no Puddle window on screen — is a wallpaper showing?")
}

// The window's own size, in points. The default is capped at something smaller and letterboxes
// what it captures, and asking for the retina pixel count pads rather than scales — either way
// the wallpaper ends up sharing the frame with a band of white that is not part of it.
let configuration = SCStreamConfiguration()
configuration.width = Int(window.frame.width)
configuration.height = Int(window.frame.height)
configuration.captureResolution = .best
configuration.showsCursor = false

let image: CGImage = try await SCScreenshotManager.captureImage(
	contentFilter: SCContentFilter(desktopIndependentWindow: window),
	configuration: configuration
)

/// Where the board is: everything that is not the flat backdrop, which is what the corner is.
func subject(of image: CGImage) -> CGRect {
	let bitmap = NSBitmapImageRep(cgImage: image)

	guard let data = bitmap.bitmapData else {
		fail("could not read the captured pixels")
	}

	let bytes = bitmap.bitsPerPixel / 8
	let row = bitmap.bytesPerRow

	func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
		let at = y * row + x * bytes
		return (Int(data[at]), Int(data[at + 1]), Int(data[at + 2]))
	}

	let background = pixel(0, 0)

	func isSubject(_ x: Int, _ y: Int) -> Bool {
		let (r, g, b) = pixel(x, y)
		// Generous: the backdrop is not perfectly flat under the board's shadow, and the shadow
		// belongs to the board anyway.
		return abs(r - background.0) + abs(g - background.1) + abs(b - background.2) > 24
	}

	var minX = image.width, minY = image.height, maxX = 0, maxY = 0

	// Every fourth pixel: this is a bounding box, not a mask.
	for y in stride(from: 0, to: image.height, by: 4) {
		for x in stride(from: 0, to: image.width, by: 4) where isSubject(x, y) {
			minX = min(minX, x)
			minY = min(minY, y)
			maxX = max(maxX, x)
			maxY = max(maxY, y)
		}
	}

	guard minX < maxX, minY < maxY else {
		fail("the wallpaper is one flat colour — is the board drawn yet?")
	}

	return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

// 16:10 around the board, with room to breathe: the wallpaper is a board on an empty backdrop,
// and cropped tight to the wood it stops looking like one.
let board = subject(of: image)
let margin = board.width * 0.12
let width = min(CGFloat(image.width), max(board.width + margin * 2, (board.height + margin * 2) * 16 / 10))
let height = min(CGFloat(image.height), width * 10 / 16)

// Centred on the board, then pushed back inside the frame rather than trimmed, so the aspect
// ratio survives a board that sits near an edge.
let crop = CGRect(
	x: min(max(0, board.midX - width / 2), CGFloat(image.width) - width),
	y: min(max(0, board.midY - height / 2), CGFloat(image.height) - height),
	width: width,
	height: height
)

guard let cropped = image.cropping(to: crop) else {
	fail("could not crop \(image.width)x\(image.height) to \(Int(width))x\(Int(height))")
}

let bitmap = NSBitmapImageRep(cgImage: cropped)

guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
	fail("could not encode a JPEG")
}

try jpeg.write(to: output)
print("wrote \(cropped.width)x\(cropped.height) to \(output.path)")
