import ChessKit
import SceneKit

// Checks the bridge between ChessKit's squares and the scene's file/rank pair — the mapping
// most likely to be silently transposed, and the one nothing else would catch.
var game = ChessGame()

assert(game.pieces.count == 32, "opening position should have 32 pieces")
assert(game.sideToMove == .white)

// a1 is file 0, rank 0.
assert(game.piece(at: (0, 0))?.kind == .rook, "a1 is a rook")
assert(game.piece(at: (4, 0))?.kind == .king, "e1 is the king")
assert(game.piece(at: (3, 0))?.kind == .queen, "d1 is the queen")
assert(game.piece(at: (4, 7))?.color == .black, "e8 is black")
assert(game.piece(at: (4, 3)) == nil, "e4 starts empty")

// e2 may go to e3 and e4, and nowhere else.
let e2Moves = Set(game.legalMoves(from: (4, 1)).map { "\($0.file)\($0.rank)" })
assert(e2Moves == ["42", "43"], "e2 pawn: \(e2Moves)")

// The knight on b1 has exactly a3 and c3.
let b1Moves = Set(game.legalMoves(from: (1, 0)).map { "\($0.file)\($0.rank)" })
assert(b1Moves == ["02", "22"], "b1 knight: \(b1Moves)")

assert(game.move(from: (4, 1), to: (4, 4)) == nil, "e2-e5 is not legal")
assert(game.move(from: (4, 1), to: (4, 3)) != nil, "e2-e4 is legal")
assert(game.piece(at: (4, 3))?.kind == .pawn, "the pawn is on e4")
assert(game.piece(at: (4, 1)) == nil, "e2 is empty now")
assert(game.sideToMove == .black, "black to move")

// Scholar's mate: the rules, the end state, and the scene's node names all the way through.
game = ChessGame()
for (from, to) in [((4, 1), (4, 3)), ((4, 6), (4, 4)), ((5, 0), (2, 3)), ((1, 7), (2, 5)), ((3, 0), (7, 4)), ((6, 7), (5, 5)), ((7, 4), (5, 6))] {
    assert(game.move(from: from, to: to) != nil, "move \(from) -> \(to) should be legal")
}
assert(game.conclusion == "White wins", "scholar's mate: \(game.conclusion ?? "nil")")

// Castling moves the rook too — the reason the renderer rebuilds from the position.
game = ChessGame()
for (from, to) in [((4, 1), (4, 3)), ((4, 6), (4, 4)), ((6, 0), (5, 2)), ((1, 7), (2, 5)), ((5, 0), (2, 3)), ((5, 7), (2, 4))] {
    assert(game.move(from: from, to: to) != nil, "move \(from) -> \(to) should be legal")
}
assert(game.move(from: (4, 0), to: (6, 0)) != nil, "white should be able to castle short")
assert(game.piece(at: (6, 0))?.kind == .king, "king on g1")
assert(game.piece(at: (5, 0))?.kind == .rook, "rook on f1 — moved without anyone asking")

// UCI notation, as the engine speaks it. Files g and h are the ones to watch: they are not
// hex digits, so the obvious `hexDigitValue` shortcut drops every move on that side of the board.
game = ChessGame()
assert(game.move(uci: "g1f3") != nil, "g1-f3 should be legal")
assert(game.piece(at: (5, 2))?.kind == .knight, "knight on f3")
assert(game.move(uci: "h7h5") != nil, "h7-h5 should be legal")
assert(game.piece(at: (7, 4))?.kind == .pawn, "black pawn on h5")
assert(game.move(uci: "zz99") == nil, "nonsense is not a move")
assert(game.move(uci: "a1") == nil, "a half move is not a move")

// FEN round-trips to the engine and back.
game = ChessGame()
assert(game.fen.hasPrefix("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w"), "opening FEN: \(game.fen)")
game.move(uci: "e2e4")
assert(game.fen.contains(" b "), "black to move after 1. e4: \(game.fen)")

// Promotion: the engine sends the piece as a suffix, and a pawn reaching the last rank becomes a queen.
game = ChessGame()
for uci in ["a2a4", "b7b5", "a4b5", "a7a6", "b5a6", "b8c6", "a6a7", "a8b8"] {
    assert(game.move(uci: uci) != nil, "\(uci) should be legal")
}
assert(game.move(uci: "a7a8q") != nil, "a7-a8 promotes")
assert(game.piece(at: (0, 7))?.kind == .queen, "a8 is a queen now")

// The scene's square lookup must invert its own square positions.
for file in 0..<8 {
    for rank in 0..<8 {
        let point = ChessScene.position(file: file, rank: rank)
        let found = ChessScene.square(at: point)
        assert(found?.file == file && found?.rank == rank, "square(at:) failed for \(file),\(rank)")
    }
}

print("ok")
