import AppKit

/**
The plugin's principal class: everything Puddle sees of this wallpaper.

Named in `Info.plist` as `NSPrincipalClass`, and `@objc` so the name in that file matches the one in the runtime.
*/
@MainActor
@objc(ChessPlugin)
final class ChessPlugin: NSObject, PuddleWallpaperPlugin {
	private let boardView = ChessBoardView()

	var view: NSView { boardView }

	func start(options: String) {
		let options = Options(options)

		guard let modelURL = Bundle(for: Self.self).url(forResource: "chess-set", withExtension: "usdz") else {
			// Nothing to draw. Puddle shows the empty view rather than the previous wallpaper, which is a clear enough signal that something is wrong with the plugin.
			return
		}

		try? boardView.start(modelURL: modelURL, mode: options.mode, enginePath: options.enginePath)
	}

	func setQuality(_ level: Int) {
		boardView.quality = Quality(level)
	}

	func stop() {
		boardView.stop()
	}
}

/**
The governor's decision, as the plugin protocol carries it.
*/
enum Quality {
	case disabled
	case reduced
	case full

	init(_ level: Int) {
		self = switch level {
		case 0: .disabled
		case 1: .reduced
		default: .full
		}
	}
}

/**
The wallpaper's option string: space-separated `key=value` pairs.

```
mode=watch
mode=play engine=/opt/homebrew/bin/stockfish
```

Unknown keys are ignored, and an empty string is a perfectly good configuration — it means "play, and find the engine yourself".
*/
struct Options {
	var mode = ChessMode.play
	var enginePath: String?

	init(_ string: String) {
		for pair in string.split(whereSeparator: \.isWhitespace) {
			let parts = pair.split(separator: "=", maxSplits: 1)

			guard parts.count == 2 else {
				continue
			}

			switch parts[0] {
			case "mode":
				mode = ChessMode(rawValue: String(parts[1])) ?? .play
			case "engine":
				enginePath = String(parts[1])
			default:
				break
			}
		}
	}
}

/**
Who plays.
*/
enum ChessMode: String {
	/// You play white in Browsing Mode; the engine answers as black. Without an engine, you move both sides.
	case play
	/// The engine plays itself, starting a new game a few seconds after each one ends.
	case watch
}
