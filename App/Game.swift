import Foundation
import SwiftUI

/// One line of the score sheet: name, score so far (n), this round's points (x), and the sign between them.
struct PlayerRow: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var base = "0"       // (n) total before this round
    var minus = false    // the +/− toggle; + unless the user picks −
    var entry = "0"      // (x) points left in hand this round

    var hasName: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// A row with a name or any points; the empty row at the bottom is not.
    var isInPlay: Bool { hasName || (Int(base) ?? 0) != 0 || (Int(entry) ?? 0) != 0 }

    /// (n ± x), or nil while the row is empty.
    var total: Int? {
        if base.isEmpty && entry.isEmpty { return nil }
        let n = Int(base) ?? 0, x = Int(entry) ?? 0
        return minus ? n - x : n + x
    }
}

struct GameState: Codable, Equatable {
    static let rounds = 13
    static let minSeats = 2
    static let maxSeats = 10

    var players: [PlayerRow] = (0..<GameState.minSeats).map { _ in PlayerRow() }
    /// The starting double picked for each round (12 down to 0, the double-blank), nil until picked.
    var starts: [Int?] = Array(repeating: nil, count: GameState.rounds)
    var roundsDone = 0
    /// Each player's (n) before every finished round, for Undo.
    var history: [[UUID: String]] = []
    /// The name the match was saved under; once set, the match is saved after every round.
    var saveName: String?

    init() {}

    private enum CodingKeys: String, CodingKey { case players, starts, roundsDone, history, saveName }

    /// Tolerant, so a match in play from an earlier version still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        players = try c.decode([PlayerRow].self, forKey: .players)
        starts = try c.decode([Int?].self, forKey: .starts)
        roundsDone = try c.decode(Int.self, forKey: .roundsDone)
        history = (try? c.decode([[UUID: String]].self, forKey: .history)) ?? []
        saveName = try c.decodeIfPresent(String.self, forKey: .saveName)
    }

    var currentRound: Int? { roundsDone < GameState.rounds ? roundsDone : nil }
    var isOver: Bool { roundsDone >= GameState.rounds }

    /// One empty row at the bottom for the next player, and never fewer than two rows.
    mutating func tidyRows() {
        // Number fields left blank go back to 0.
        for i in players.indices {
            if players[i].base.isEmpty { players[i].base = "0" }
            if players[i].entry.isEmpty { players[i].entry = "0" }
        }
        while players.count > GameState.minSeats,
              !players[players.count - 1].isInPlay, !players[players.count - 2].isInPlay {
            players.removeLast()
        }
        if let last = players.last, last.isInPlay, players.count < GameState.maxSeats {
            players.append(PlayerRow())
        }
        while players.count < GameState.minSeats { players.append(PlayerRow()) }
    }
}

/// What a saved match keeps: the names and totals, plus how far the match has gone.
struct SavedMatch: Codable, Identifiable {
    struct Player: Codable { var name: String; var total: Int }

    var name: String
    var saved: Date
    var players: [Player]
    var roundsDone: Int
    var starts: [Int?]

    var id: String { name }

    var summary: String {
        let scores = players.map { "\($0.name) \($0.total)" }.joined(separator: ", ")
        let round = roundsDone == 0 ? "not started" : "after round \(roundsDone)"
        return "\(scores)\n\(round) · \(saved.formatted(date: .abbreviated, time: .shortened))"
    }
}

@MainActor
final class Game: ObservableObject {
    private static let key = "DominUno.game"

    @Published var state: GameState {
        didSet { remember() }
    }

    init() {
        var s = GameState()
        if let data = UserDefaults.standard.data(forKey: Game.key),
           let saved = try? JSONDecoder().decode(GameState.self, from: data) {
            s = saved
        }
        while s.starts.count < GameState.rounds { s.starts.append(nil) }
        s.tidyRows()
        state = s
    }

    /// The match in play survives the app being closed.
    private func remember() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Game.key)
        }
    }

    // MARK: Players

    /// Typing a name opens a new row below it. Someone joining after a round has been played
    /// starts at the average of everyone's totals plus 10%.
    func setName(_ id: UUID, _ name: String) {
        guard let i = state.players.firstIndex(where: { $0.id == id }) else { return }
        var s = state
        let joining = !s.players[i].hasName && s.roundsDone > 0
            && (Int(s.players[i].base) ?? 0) == 0 && (Int(s.players[i].entry) ?? 0) == 0
        s.players[i].name = name
        if joining && s.players[i].hasName {
            let totals = s.players.indices.filter { $0 != i && s.players[$0].isInPlay }
                .compactMap { Int(s.players[$0].base) }
            if !totals.isEmpty {
                let average = Double(totals.reduce(0, +)) / Double(totals.count)
                s.players[i].base = String(Int((average * 1.1).rounded()))
            }
        }
        s.tidyRows()
        state = s
    }

    func clearZero(_ id: UUID, base: Bool) {
        guard let i = state.players.firstIndex(where: { $0.id == id }) else { return }
        if base, state.players[i].base == "0" { state.players[i].base = "" }
        if !base, state.players[i].entry == "0" { state.players[i].entry = "" }
    }

    func tidyRows() {
        var s = state
        s.tidyRows()
        if s != state { state = s }
    }

    // MARK: Rounds

    /// Tap a double in the green row: it becomes this round's starting double (tap again to clear).
    func pickStart(_ pips: Int) {
        guard let r = state.currentRound else { return }
        state.starts[r] = state.starts[r] == pips ? nil : pips
    }

    /// Finish the round: every total becomes the next round's (n).
    func nextRound() {
        guard !state.isOver else { return }
        var s = state
        s.history.append(Dictionary(uniqueKeysWithValues: s.players.map { ($0.id, $0.base) }))
        for i in s.players.indices where s.players[i].isInPlay {
            s.players[i].base = String(s.players[i].total ?? 0)
            s.players[i].entry = "0"
            s.players[i].minus = false
        }
        s.roundsDone += 1
        state = s
        autosave()
    }

    var canUndo: Bool { !state.history.isEmpty }

    /// Take back the last finished round.
    func undoRound() {
        var s = state
        guard let bases = s.history.popLast() else { return }
        for i in s.players.indices {
            s.players[i].base = bases[s.players[i].id] ?? "0"
            s.players[i].entry = "0"
            s.players[i].minus = false
        }
        s.roundsDone -= 1
        s.tidyRows()
        state = s
        autosave()
    }

    /// A new match: two empty player rows, nothing picked, not saved.
    func newGame() {
        state = GameState()
    }

    /// Lowest total wins; ties share the win.
    var winners: (names: [String], score: Int)? {
        let inPlay = state.players.filter(\.isInPlay)
        guard let best = inPlay.compactMap({ Int($0.base) }).min() else { return nil }
        let names = inPlay.filter { Int($0.base) == best }.map { $0.hasName ? $0.name : "?" }
        return (names, best)
    }

    // MARK: Saved matches (Documents/Matches/<name>.json)

    private static var folder: URL {
        let url = URL.documentsDirectory.appending(path: "Matches", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(for name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return folder.appending(path: safe + ".json")
    }

    func save(as name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let match = SavedMatch(
            name: name, saved: .now,
            players: state.players.filter(\.isInPlay).map {
                .init(name: $0.name, total: Int($0.base) ?? 0)
            },
            roundsDone: state.roundsDone, starts: state.starts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(match) {
            try? data.write(to: Game.file(for: name), options: .atomic)
        }
        if state.saveName != name { state.saveName = name }
    }

    private func autosave() {
        if let name = state.saveName { save(as: name) }
    }

    func savedMatches() -> [SavedMatch] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: Game.folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SavedMatch.self, from: Data(contentsOf: $0)) }
            .sorted { $0.saved > $1.saved }
    }

    func open(_ match: SavedMatch) {
        var s = GameState()
        s.players = match.players.map { p in
            var row = PlayerRow()
            row.name = p.name
            row.base = String(p.total)
            return row
        }
        s.roundsDone = min(match.roundsDone, GameState.rounds)
        for (i, d) in match.starts.prefix(GameState.rounds).enumerated() { s.starts[i] = d }
        s.saveName = match.name
        s.tidyRows()
        state = s
    }

    func delete(_ match: SavedMatch) {
        try? FileManager.default.removeItem(at: Game.file(for: match.name))
        if state.saveName == match.name { state.saveName = nil }
    }
}
