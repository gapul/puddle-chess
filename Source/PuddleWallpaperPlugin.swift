import AppKit

/**
Puddle's wallpaper plugin interface, copied verbatim from `Puddle/PluginRenderer.swift`.

This is deliberately a copy rather than a dependency. Nothing is linked between the two: both sides declare the same `@objc` protocol and the Objective-C runtime matches them by name, so a plugin needs no framework, no package, and no build-time knowledge of Puddle at all.

Everything here is called on the main thread.

The explicit `@objc(PuddleWallpaperPlugin)` name is what makes the trick work: without it Swift mangles the runtime name with the declaring module, and the two protocols stop being the same protocol.

Keep it in step with Puddle's copy.
*/
@MainActor
@objc(PuddleWallpaperPlugin) protocol PuddleWallpaperPlugin: NSObjectProtocol {
	/// The view to show. Read once, right after the plugin is created.
	var view: NSView { get }

	/// Begin. `options` is the wallpaper's option string, straight through.
	func start(options: String)

	/// The render governor's decision: 0 = stopped, 1 = reduced, 2 = full.
	@objc optional func setQuality(_ level: Int)

	/// Tear down. The plugin is being swapped out.
	@objc optional func stop()
}
