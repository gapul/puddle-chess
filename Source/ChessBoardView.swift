import AppKit
import SceneKit

/**
The board: a chess set you can play on, or watch.

A wallpaper sits at desktop level and gets no clicks, so the board is only playable while Puddle's Browsing Mode is on. The rest of the time it is a still life, and costs what a still life costs: the scene only runs its clock while a piece is moving.
*/
@MainActor
final class ChessBoardView: SCNView {
	private var model: SCNScene?
	private var game = ChessGame()
	private var mode = ChessMode.play
	private var engine: ChessEngine?
	private var selection: (file: Int, rank: Int)?
	private var isAnimating = false
	private var engineTurn: Task<Void, Never>?

	var quality = Quality.full {
		didSet {
			applyQuality()
		}
	}

	init() {
		super.init(frame: .zero, options: nil)
		allowsCameraControl = false
		// The board only moves when a piece does, so the render loop stays off until then.
		rendersContinuously = false
		isPlaying = false
		backgroundColor = currentAppearance.background
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError() // swiftlint:disable:this fatal_error_message
	}

	deinit {
		engineTurn?.cancel()
	}

	/**
	Stop everything: no rendering, and nothing left thinking in another process.
	*/
	func stop() {
		engineTurn?.cancel()
		engineTurn = nil
		engine = nil
		isPlaying = false
	}

	func start(modelURL: URL, mode: ChessMode, enginePath: String?) throws {
		engineTurn?.cancel()
		engineTurn = nil

		let model = try SCNScene(url: modelURL)
		self.model = model
		self.mode = mode
		game = ChessGame()
		selection = nil

		scene = try ChessScene.make(model: model, pieces: game.pieces, appearance: currentAppearance)
		pointOfView = scene?.rootNode.childNode(withName: ChessScene.cameraName, recursively: false)
		applyQuality()
		// With the render loop off, nothing else would ask for the first frame, and the board
		// would stay blank until the first move.
		render()

		// A missing engine is not an error: without one, `play` becomes a board you move both
		// sides on by hand, which is a perfectly good wallpaper.
		if engine == nil, let executable = ChessEngine.locate(configured: enginePath) {
			engine = try? ChessEngine(executable: executable)
		}

		engine?.newGame()
		startEngineTurnIfItsTheirMove()
	}

	// MARK: - Playing

	override func mouseDown(with event: NSEvent) {
		// In `watch` the board is a spectator sport; in `play` a click during the engine's turn would let you move its pieces for it.
		guard mode == .play, !isAnimating, engineTurn == nil else {
			return
		}

		guard let square = square(at: convert(event.locationInWindow, from: nil)) else {
			clearSelection()
			return
		}

		if let selection, game.legalMoves(from: selection).contains(where: { $0 == square }) {
			clearSelection()
			perform(from: selection, to: square)
			return
		}

		select(square)
	}

	/**
	Which square the click landed on, from whatever it hit — a piece counts as its own square.
	*/
	private func square(at point: CGPoint) -> (file: Int, rank: Int)? {
		let hits = hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])

		for hit in hits {
			if let square = Self.square(ofPieceNode: hit.node) {
				return square
			}

			// The board is at the scene's origin with no transform, so world coordinates are board coordinates.
			if let square = ChessScene.square(at: hit.worldCoordinates) {
				return square
			}
		}

		return nil
	}

	/**
	Walks up from whatever mesh was hit to the piece node that owns it, and reads the square out of its name.
	*/
	private static func square(ofPieceNode node: SCNNode) -> (file: Int, rank: Int)? {
		var current: SCNNode? = node

		while let candidate = current {
			if
				let name = candidate.name,
				name.hasPrefix("piece-"),
				let squarePart = name.split(separator: "-").last,
				squarePart.count == 2,
				let file = squarePart.first?.wholeNumberValue,
				let rank = squarePart.last?.wholeNumberValue
			{
				return (file, rank)
			}

			current = candidate.parent
		}

		return nil
	}

	private func select(_ square: (file: Int, rank: Int)) {
		clearSelection()

		// Only the side to move can be picked up; clicking anything else just deselects.
		guard let piece = game.piece(at: square), piece.color == game.sideToMove else {
			return
		}

		selection = square

		for target in game.legalMoves(from: square) {
			scene?.rootNode.addChildNode(ChessScene.makeMarker(
				file: target.file,
				rank: target.rank,
				isCapture: game.piece(at: target) != nil
			))
		}

		lift(square, by: liftHeight)
		render()
	}

	private func clearSelection() {
		if let selection {
			lift(selection, by: 0)
		}

		selection = nil
		removeMarkers()
		render()
	}

	private func removeMarkers() {
		scene?.rootNode.childNodes { node, _ in node.name == ChessScene.markerName }
			.forEach { $0.removeFromParentNode() }
	}

	/**
	Play a move that has already been found legal, animate it, and hand over to whoever moves next.
	*/
	private func perform(from: (file: Int, rank: Int), to: (file: Int, rank: Int)) {
		let node = pieceNode(at: from)

		guard game.move(from: from, to: to) != nil else {
			render()
			return
		}

		isAnimating = true
		applyQuality()

		let slide = SCNAction.move(to: ChessScene.position(file: to.file, rank: to.rank), duration: 0.35)
		slide.timingMode = .easeInEaseOut

		// The board is rebuilt from the position afterwards, which is what makes castling, en
		// passant, captures, and promotion all land without being handled one by one here.
		guard let node else {
			finishMove()
			return
		}

		node.runAction(slide) { [weak self] in
			Task { @MainActor in
				self?.finishMove()
			}
		}
	}

	private func finishMove() {
		rebuildPieces()
		isAnimating = false
		applyQuality()
		startEngineTurnIfItsTheirMove()
	}

	// MARK: - The engine

	/**
	Whether the engine owns the side to move: both sides in `watch`, black in `play`.
	*/
	private var isEnginesMove: Bool {
		switch mode {
		case .watch: true
		case .play: game.sideToMove == .black
		}
	}

	private func startEngineTurnIfItsTheirMove() {
		engineTurn?.cancel()
		engineTurn = nil

		guard let engine, isEnginesMove, quality != .disabled else {
			return
		}

		guard game.conclusion == nil else {
			// In `watch` the board would sit on a finished game forever, so it starts another.
			if mode == .watch {
				engineTurn = Task { [weak self] in
					try? await Task.sleep(for: .seconds(8))
					guard !Task.isCancelled else { return }
					self?.engineTurn = nil
					self?.restart()
				}
			}

			return
		}

		engineTurn = Task { [weak self] in
			guard let self else {
				return
			}

			// A pause in `watch`, so moves land at a pace someone can follow rather than as fast as Stockfish can answer.
			if mode == .watch {
				try? await Task.sleep(for: .seconds(1.2))
			}

			guard !Task.isCancelled else {
				return
			}

			let move = await engine.bestMove(fen: game.fen, milliseconds: Self.thinkingTime)

			guard !Task.isCancelled, let move, let squares = game.move(uci: move) else {
				self.engineTurn = nil
				return
			}

			self.engineTurn = nil
			animateEngineMove(squares)
		}
	}

	/**
	The engine has already been applied to the game by this point; this only moves the node to match, then rebuilds like any other move.
	*/
	private func animateEngineMove(_ squares: (from: (file: Int, rank: Int), to: (file: Int, rank: Int))) {
		let node = pieceNode(at: squares.from)
		isAnimating = true
		applyQuality()

		let slide = SCNAction.move(to: ChessScene.position(file: squares.to.file, rank: squares.to.rank), duration: 0.35)
		slide.timingMode = .easeInEaseOut

		guard let node else {
			finishMove()
			return
		}

		node.runAction(slide) { [weak self] in
			Task { @MainActor in
				self?.finishMove()
			}
		}
	}

	/**
	Milliseconds per move. A wallpaper's budget, not a tournament's — Stockfish is already far beyond anyone watching a desktop.
	*/
	private static let thinkingTime = 300

	private func restart() {
		guard let model else {
			return
		}

		game = ChessGame()
		selection = nil
		engine?.newGame()
		scene = try? ChessScene.make(model: model, pieces: game.pieces, appearance: currentAppearance)
		pointOfView = scene?.rootNode.childNode(withName: ChessScene.cameraName, recursively: false)
		applyQuality()
		startEngineTurnIfItsTheirMove()
	}

	// MARK: - Pieces

	private func rebuildPieces() {
		guard let scene, let model else {
			return
		}

		scene.rootNode.childNodes { node, _ in node.name?.hasPrefix("piece-") == true }
			.forEach { $0.removeFromParentNode() }

		for node in ChessScene.pieceNodes(game.pieces, from: model) {
			scene.rootNode.addChildNode(node)
		}

		render()
	}

	private func pieceNode(at square: (file: Int, rank: Int)) -> SCNNode? {
		scene?.rootNode.childNodes { node, _ in
			node.name?.hasSuffix("-\(square.file)\(square.rank)") == true && node.name?.hasPrefix("piece-") == true
		}.first
	}

	/**
	Raises the piece on a square, so the one you picked up is obvious.
	*/
	private func lift(_ square: (file: Int, rank: Int), by height: CGFloat) {
		pieceNode(at: square)?.position.y = height
	}

	private let liftHeight: CGFloat = 0.25

	// MARK: - Appearance

	private var currentAppearance: ChessScene.Appearance {
		.init(isDark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		applyAppearance()
	}

	private func applyAppearance() {
		// Also the view's own backdrop: it is what shows in the moment before the first frame is drawn, and white there is a flash of daylight on a dark desktop.
		backgroundColor = currentAppearance.background

		guard let scene else {
			return
		}

		ChessScene.apply(currentAppearance, to: scene)
		render()
	}

	// MARK: - Quality

	private func applyQuality() {
		switch quality {
		case .disabled:
			isPlaying = false
			// Nothing should be thinking while the wallpaper is asleep, locked, or off on battery.
			engineTurn?.cancel()
			engineTurn = nil
			engine?.cancel()
		case .reduced:
			preferredFramesPerSecond = 8
			antialiasingMode = .none
			isPlaying = isAnimating
			startEngineTurnIfItsTheirMove()
		case .full:
			preferredFramesPerSecond = 24
			antialiasingMode = .multisampling2X
			isPlaying = isAnimating
			startEngineTurnIfItsTheirMove()
		}
	}

	/**
	Draw one frame. With the render loop off, every change to the board needs to ask for one.
	*/
	private func render() {
		setNeedsDisplay(bounds)
	}
}
