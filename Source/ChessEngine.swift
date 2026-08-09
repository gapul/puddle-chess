import Foundation

/**
Stockfish, spoken to over UCI in a process of its own.

Deliberately a separate program rather than a linked library: Stockfish is GPLv3, and Puddle is not. Running it as its own process keeps that boundary, and costs nothing — UCI is a line protocol over a pipe.

The binary is not bundled. It is found on the machine, or the board simply has no opponent.
*/
@MainActor
final class ChessEngine {
	private let process = Process()
	private let input = Pipe()
	private let output = Pipe()

	private var pendingMove: CheckedContinuation<String?, Never>?
	private var buffer = ""

	/**
	Where a Stockfish install tends to land. A GUI app inherits a bare `PATH` from launchd, so looking it up is not enough — these have to be named.
	*/
	private static let candidates = [
		"/opt/homebrew/bin/stockfish",
		"/usr/local/bin/stockfish",
		"/run/current-system/sw/bin/stockfish",
		"\(NSHomeDirectory())/.nix-profile/bin/stockfish",
		"/nix/var/nix/profiles/default/bin/stockfish"
	]

	/**
	Find the engine. `configured` is the path from the wallpaper's options, when it is somewhere the search would not think to look.
	*/
	static func locate(configured: String? = nil) -> URL? {
		if let configured, !configured.isEmpty {
			return FileManager.default.isExecutableFile(atPath: configured) ? URL(fileURLWithPath: configured) : nil
		}

		let paths = candidates + (ProcessInfo.processInfo.environment["PATH"] ?? "")
			.split(separator: ":")
			.map { "\($0)/stockfish" }

		return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
	}

	init(executable: URL) throws {
		process.executableURL = executable
		process.standardInput = input
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice

		process.terminationHandler = { [weak self] _ in
			Task { @MainActor in
				// A crashed engine must not leave the board waiting for a move that will never come.
				self?.resumePendingMove(with: nil)
			}
		}

		output.fileHandleForReading.readabilityHandler = { [weak self] handle in
			let text = String(decoding: handle.availableData, as: UTF8.self)

			guard !text.isEmpty else {
				return
			}

			Task { @MainActor in
				self?.receive(text)
			}
		}

		try process.run()
		send("uci")
		// A wallpaper's opponent should stay out of the way: one thread and a small table are
		// plenty at this time control, and the defaults scale with the machine.
		send("setoption name Threads value 1")
		send("setoption name Hash value 16")
		send("isready")
	}

	deinit {
		process.terminationHandler = nil
		process.terminate()
	}

	/**
	Start a fresh game. Clears the engine's memory of the previous one.
	*/
	func newGame() {
		send("ucinewgame")
		send("isready")
	}

	/**
	The engine's move for a position, in UCI notation (`e2e4`, `e7e8q`), or `nil` if it never answered.

	`milliseconds` is a wallpaper's budget, not a tournament's: a fraction of a second is more than enough to play well above anyone watching a desktop.
	*/
	func bestMove(fen: String, milliseconds: Int) async -> String? {
		guard process.isRunning else {
			return nil
		}

		// One question at a time; a second would race for the same answer.
		resumePendingMove(with: nil)

		return await withCheckedContinuation { continuation in
			pendingMove = continuation
			send("position fen \(fen)")
			send("go movetime \(milliseconds)")
		}
	}

	/**
	Abandon the move being searched, if any.
	*/
	func cancel() {
		guard pendingMove != nil else {
			return
		}

		send("stop")
		resumePendingMove(with: nil)
	}

	private func send(_ command: String) {
		guard process.isRunning else {
			return
		}

		try? input.fileHandleForWriting.write(contentsOf: Data("\(command)\n".utf8))
	}

	private func receive(_ text: String) {
		buffer += text

		// UCI is line-based, but a pipe read can land mid-line; whatever trails stays for the next one.
		while let newline = buffer.firstIndex(of: "\n") {
			let line = String(buffer[..<newline])
			buffer = String(buffer[buffer.index(after: newline)...])

			guard line.hasPrefix("bestmove") else {
				continue
			}

			let move = line.split(separator: " ").dropFirst().first.map(String.init)
			resumePendingMove(with: move == "(none)" ? nil : move)
		}
	}

	private func resumePendingMove(with move: String?) {
		guard let continuation = pendingMove else {
			return
		}

		pendingMove = nil
		continuation.resume(returning: move)
	}
}
