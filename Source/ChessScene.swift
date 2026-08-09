import SceneKit

/**
The chess set: board, pieces, camera, and lighting, built from the bundled model.

Pure SceneKit with no Puddle types, so the look can be iterated on by compiling this file into a small offscreen harness that renders a PNG — much faster than launching the app to look at a wallpaper.

The model arrives normalised to the board: one square is one unit, every piece stands with its base at y = 0, and the board's top face is the y = 0 plane. Nothing here scales anything.
*/
enum ChessScene {
	enum PieceKind: String, CaseIterable {
		case pawn = "Pawn"
		case rook = "Rook"
		case knight = "Knight"
		case bishop = "Bishop"
		case queen = "Queen"
		case king = "King"
	}

	struct Piece {
		var kind: PieceKind
		var isWhite: Bool
		/// 0-7 from a to h.
		var file: Int
		/// 0-7 from white's home rank.
		var rank: Int

		/// The node name in the model file.
		var modelName: String { "\(kind.rawValue)_\(isWhite ? "White" : "Black")" }
	}

	/**
	The standard opening position.
	*/
	static var initialPieces: [Piece] {
		let back: [PieceKind] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]

		return (0..<8).flatMap { file in
			[
				Piece(kind: back[file], isWhite: true, file: file, rank: 0),
				Piece(kind: .pawn, isWhite: true, file: file, rank: 1),
				Piece(kind: .pawn, isWhite: false, file: file, rank: 6),
				Piece(kind: back[file], isWhite: false, file: file, rank: 7)
			]
		}
	}

	/**
	Build the whole scene. `modelURL` holds the board as `Board` and each piece as `<Kind>_<White|Black>`.
	*/
	static func make(modelURL: URL, pieces: [Piece] = initialPieces, appearance: Appearance = .dark) throws -> SCNScene {
		try make(model: SCNScene(url: modelURL), pieces: pieces, appearance: appearance)
	}

	/**
	Build the scene from an already-loaded model. The renderer keeps the model around to clone more pieces from as the game goes on.
	*/
	static func make(model: SCNScene, pieces: [Piece] = initialPieces, appearance: Appearance = .dark) throws -> SCNScene {
		let scene = SCNScene()
		// Stands in for an HDR environment: enough to give the polished pieces something to reflect without shipping a cube map.
		// It has to be an image, and 2:1 — SceneKit does not accept a flat colour as an environment and quietly lights from the background instead.
		scene.lightingEnvironment.contents = environmentImage

		guard let board = model.rootNode.childNode(withName: "Board", recursively: true) else {
			throw CocoaError(.fileReadCorruptFile)
		}

		// Cloned rather than moved: the model stays intact for the pieces cloned out of it later.
		let boardNode = board.clone()
		boardNode.castsShadow = false
		scene.rootNode.addChildNode(boardNode)
		scene.rootNode.addChildNode(makeCamera())

		for light in makeLights() {
			scene.rootNode.addChildNode(light)
		}

		for node in pieceNodes(pieces, from: model) {
			scene.rootNode.addChildNode(node)
		}

		apply(appearance, to: scene)

		return scene
	}

	/**
	A node per piece, named so the renderer can find which square each one stands on.
	*/
	static func pieceNodes(_ pieces: [Piece], from model: SCNScene) -> [SCNNode] {
		pieces.compactMap { piece in
			guard let template = model.rootNode.childNode(withName: piece.modelName, recursively: true) else {
				return nil
			}

			let node = template.clone()
			node.position = position(file: piece.file, rank: piece.rank)
			node.name = nodeName(for: piece)
			return node
		}
	}

	/**
	The disc that marks a square a selected piece may move to.
	*/
	static func makeMarker(file: Int, rank: Int, isCapture: Bool) -> SCNNode {
		let marker = SCNNode(geometry: SCNCylinder(radius: isCapture ? 0.46 : 0.16, height: 0.02))
		let material = SCNMaterial()
		material.lightingModel = .constant
		material.diffuse.contents = NSColor(red: 1, green: 0.85, blue: 0.4, alpha: isCapture ? 0.5 : 0.85)
		material.isDoubleSided = true
		material.writesToDepthBuffer = false
		marker.geometry?.materials = [material]
		marker.castsShadow = false
		marker.renderingOrder = 10
		marker.name = markerName
		marker.position = position(file: file, rank: rank)
		// Just clear of the board so it does not fight the surface for the same pixels.
		marker.position.y = 0.015
		return marker
	}

	static let markerName = "marker"

	/**
	Centre of a square, on the board's surface. The board is centred on the origin with white at +Z, the side the camera is on.
	*/
	static func position(file: Int, rank: Int) -> SCNVector3 {
		SCNVector3(CGFloat(file) - 3.5, 0, 3.5 - CGFloat(rank))
	}

	/**
	Which square a point on the board falls in, or `nil` when it is on the frame rather than the playing area.
	*/
	static func square(at point: SCNVector3) -> (file: Int, rank: Int)? {
		let file = Int((CGFloat(point.x) + 4).rounded(.down))
		let rank = Int((4 - CGFloat(point.z)).rounded(.down))

		guard (0..<8).contains(file), (0..<8).contains(rank) else {
			return nil
		}

		return (file, rank)
	}

	static func nodeName(for piece: Piece) -> String {
		"piece-\(piece.modelName)-\(piece.file)\(piece.rank)"
	}

	// MARK: - Camera and light

	/**
	Looks down the board from behind white, the angle a player sees.
	*/
	private static func makeCamera() -> SCNNode {
		let camera = SCNCamera()
		camera.fieldOfView = 45
		camera.zNear = 1
		camera.zFar = 80
		camera.wantsHDR = true
		// Without this the exposure drifts between renders, so the whole board changes brightness
		// every time a move forces a new frame.
		camera.wantsExposureAdaptation = false
		camera.bloomIntensity = 0.2
		camera.bloomThreshold = 0.85

		let node = SCNNode()
		node.name = cameraName
		node.camera = camera
		// Steep enough that white's own back rank does not hide the pawns behind it.
		node.position = SCNVector3(0, 16.5, 8.4)
		node.eulerAngles.x = -1.1

		return node
	}

	static let cameraName = "Camera"

	/**
	Light or dark, following the system.

	Only the surroundings change: the marble and jade are painted into the model's textures, so what can answer to the appearance is the light the board sits in — a dark room, or a bright one.

	The lift for the light room is deliberately small. Enough light to keep the board from reading as a dark blob against a pale desktop, and no more: pile on ambient and the marble blows out until the frame's own colour has changed, which is not what "follow the appearance" should mean.
	*/
	enum Appearance {
		case dark
		case light

		init(isDark: Bool) {
			self = isDark ? .dark : .light
		}

		var background: NSColor {
			switch self {
			case .dark: NSColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
			case .light: NSColor(red: 0.90, green: 0.89, blue: 0.87, alpha: 1)
			}
		}

		var environmentIntensity: CGFloat {
			switch self {
			case .dark: 1.6
			case .light: 1.8
			}
		}

		var keyIntensity: CGFloat {
			switch self {
			case .dark: 1100
			case .light: 1200
			}
		}

		var fillIntensity: CGFloat {
			switch self {
			case .dark: 300
			case .light: 340
			}
		}

		var ambientIntensity: CGFloat {
			switch self {
			case .dark: 150
			case .light: 210
			}
		}

		/// A shadow as dark as the dark room's would read as a smudge against a light background.
		var shadowAlpha: CGFloat {
			switch self {
			case .dark: 0.5
			case .light: 0.42
			}
		}
	}

	/**
	Re-light an existing scene for the current appearance. Cheap enough to call on every appearance change — nothing is rebuilt.
	*/
	static func apply(_ appearance: Appearance, to scene: SCNScene) {
		scene.background.contents = appearance.background
		scene.lightingEnvironment.intensity = appearance.environmentIntensity

		for (name, intensity) in [
			(keyLightName, appearance.keyIntensity),
			(fillLightName, appearance.fillIntensity),
			(ambientLightName, appearance.ambientIntensity)
		] {
			scene.rootNode.childNode(withName: name, recursively: false)?.light?.intensity = intensity
		}

		scene.rootNode.childNode(withName: keyLightName, recursively: false)?.light?.shadowColor =
			NSColor(white: 0, alpha: appearance.shadowAlpha)
	}

	/// A plain grey environment. An image because a colour is not accepted as one, 2:1 because that is the equirectangular shape expected.
	private static let environmentImage: NSImage = {
		let size = NSSize(width: 128, height: 64)
		let image = NSImage(size: size)
		image.lockFocus()
		NSColor(white: 0.5, alpha: 1).setFill()
		NSRect(origin: .zero, size: size).fill()
		image.unlockFocus()
		return image
	}()

	private static let keyLightName = "light-key"
	private static let fillLightName = "light-fill"
	private static let ambientLightName = "light-ambient"

	private static func makeLights() -> [SCNNode] {
		// Key light: casts the shadows that give the pieces their weight.
		let key = SCNLight()
		key.type = .directional
		key.intensity = 1100
		key.castsShadow = true
		key.shadowMode = .deferred
		key.shadowRadius = 8
		key.shadowSampleCount = 16
		key.shadowColor = NSColor(white: 0, alpha: 0.5)
		key.maximumShadowDistance = 50
		key.orthographicScale = 9

		let keyNode = SCNNode()
		keyNode.name = keyLightName
		keyNode.light = key
		keyNode.position = SCNVector3(-8, 16, 8)
		keyNode.eulerAngles = SCNVector3(-0.9, -0.5, 0)

		// Fill: lifts the shadow side so the black pieces do not go to silhouette.
		let fill = SCNLight()
		fill.type = .omni
		fill.intensity = 300
		fill.attenuationEndDistance = 50

		let fillNode = SCNNode()
		fillNode.name = fillLightName
		// Far enough off the board that it lifts the shadow side without burning a highlight into the frame.
		fillNode.position = SCNVector3(16, 13, -11)
		fillNode.light = fill

		let ambient = SCNLight()
		ambient.type = .ambient
		ambient.intensity = 150

		let ambientNode = SCNNode()
		ambientNode.name = ambientLightName
		ambientNode.light = ambient

		return [keyNode, fillNode, ambientNode]
	}
}
