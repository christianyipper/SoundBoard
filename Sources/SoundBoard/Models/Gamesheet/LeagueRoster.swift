import Foundation

/// League rosters and season stats, scraped daily from the JPHL site into
/// `rosters/rosters.json` by the Update rosters GitHub Action.
struct LeagueData: Codable, Equatable {
    var updatedAt: Date
    var seasonId: Int?
    var divisions: [RosterDivision]

    func team(id: Int) -> RosterTeam? {
        divisions.lazy.flatMap(\.teams).first { $0.id == id }
    }
}

struct RosterDivision: Codable, Equatable, Identifiable {
    var id: Int
    var name: String
    var teams: [RosterTeam]
}

struct RosterTeam: Codable, Equatable, Identifiable {
    var id: Int
    var name: String
    /// Games the league has posted for this team. Nil in data scraped
    /// before it was added.
    var gp: Int?
    var players: [RosterPlayer]

    var gamesPlayed: Int { gp ?? players.map(\.gp).max() ?? 0 }

    /// The player wearing `number`, ignoring leading zeros ("07" matches "7").
    func player(number: String) -> RosterPlayer? {
        let key = RosterPlayer.normalized(number)
        guard !key.isEmpty else { return nil }
        return players.first { RosterPlayer.normalized($0.number) == key }
    }
}

struct RosterPlayer: Codable, Equatable, Identifiable {
    var id: Int
    var number: String
    var name: String
    var position: String
    var gp: Int
    var goals: Int
    var assists: Int
    var points: Int
    var pim: Int

    /// The last word of the name, for tight spaces like the penalty rows.
    var surname: String {
        name.split(separator: " ").last.map(String.init) ?? name
    }

    static func normalized(_ number: String) -> String {
        let trimmed = number.trimmingCharacters(in: .whitespaces)
        let stripped = trimmed.drop { $0 == "0" }
        return stripped.isEmpty && !trimmed.isEmpty ? "0" : String(stripped)
    }
}

/// What a typed jersey number resolves to on a side's roster.
enum PlayerLookup: Equatable {
    /// The side has no roster, so nothing to show.
    case noRoster
    case notOnRoster
    /// `seasonGoals` includes goals recorded in the current game.
    case player(RosterPlayer, seasonGoals: Int)
}
