import ChessKit

/**
The rules, in the terms the scene speaks.

ChessKit owns legality, castling, en passant, and the end-of-game states; this exists only to translate between its `Square` and the scene's file/rank pair, and to hand back the position as scene pieces.
*/
struct ChessGame {
	private(set) var board = Board()

	/**
	Whose turn it is.
	*/
	var sideToMove: Piece.Color { board.position.sideToMove }

	/**
	The position as the scene wants it: one entry per piece, in file/rank.
	*/
	var pieces: [ChessScene.Piece] {
		board.position.pieces.map {
			ChessScene.Piece(
				kind: ChessScene.PieceKind($0.kind),
				isWhite: $0.color == .white,
				file: $0.square.file.number - 1,
				rank: $0.square.rank.value - 1
			)
		}
	}

	/**
	The piece standing on a square, if any.
	*/
	func piece(at square: (file: Int, rank: Int)) -> Piece? {
		board.position.pieces.first { $0.square == Self.square(square) }
	}

	/**
	Where the piece on this square may legally go.
	*/
	func legalMoves(from square: (file: Int, rank: Int)) -> [(file: Int, rank: Int)] {
		board.legalMoves(forPieceAt: Self.square(square)).map {
			($0.file.number - 1, $0.rank.value - 1)
		}
	}

	/**
	Play a move, if it is legal. Returns the move for the caller to animate, or `nil` when it was not.
	*/
	@discardableResult
	mutating func move(from: (file: Int, rank: Int), to: (file: Int, rank: Int)) -> Move? {
		guard let move = board.move(pieceAt: Self.square(from), to: Self.square(to)) else {
			return nil
		}

		// ponytail: pawns always promote to a queen. Offering the choice needs UI on a desktop-level window; underpromotion is rare enough to wait for someone to ask.
		if case .promotion(let promotion) = board.state {
			board.completePromotion(of: promotion, to: .queen)
		}

		return move
	}

	/**
	The position in FEN, which is how the engine is told where the game stands.
	*/
	var fen: String { board.position.fen }

	/**
	Play a move given in UCI notation (`e2e4`, `e7e8q` for a promotion), as engines speak it.
	*/
	@discardableResult
	mutating func move(uci: String) -> (from: (file: Int, rank: Int), to: (file: Int, rank: Int))? {
		let characters = Array(uci)

		guard
			characters.count >= 4,
			let fromFile = Self.fileIndex(characters[0]),
			let fromRank = characters[1].wholeNumberValue,
			let toFile = Self.fileIndex(characters[2]),
			let toRank = characters[3].wholeNumberValue
		else {
			return nil
		}

		let from = (file: fromFile, rank: fromRank - 1)
		let to = (file: toFile, rank: toRank - 1)

		guard move(from: from, to: to) != nil else {
			return nil
		}

		return (from, to)
	}

	/**
	Whether the game is over, and how — `nil` while it is still being played.
	*/
	var conclusion: String? {
		switch board.state {
		case .checkmate(let color):
			"\(color == .white ? "Black" : "White") wins"
		case .draw(let reason):
			"Draw by \(reason.rawValue)"
		case .active, .check, .promotion:
			nil
		}
	}

	/**
	`a`–`h` to 0–7. Not `hexDigitValue`, which has no answer for `g` and `h` and would quietly drop every move on those two files.
	*/
	private static func fileIndex(_ character: Character) -> Int? {
		guard let ascii = character.asciiValue, ("a"..."h").contains(character) else {
			return nil
		}

		return Int(ascii) - Int(Character("a").asciiValue!)
	}

	private static func square(_ square: (file: Int, rank: Int)) -> Square {
		// ChessKit orders its squares a1…h8, so this is the same index the scene uses.
		Square(rawValue: square.rank * 8 + square.file) ?? .a1
	}
}

extension ChessScene.PieceKind {
	init(_ kind: Piece.Kind) {
		self = switch kind {
		case .pawn: .pawn
		case .rook: .rook
		case .knight: .knight
		case .bishop: .bishop
		case .queen: .queen
		case .king: .king
		}
	}
}
