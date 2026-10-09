import Foundation

/// The gamesheet information a saved game keeps: team names and rosters, shots, goalkeepers,
/// officials, and the recorded goals (with assists) and penalties. The current period and clock time aren't
/// saved.
struct GameRecord: Codable, Equatable {
    var teamNames: [TeamSide: String]
    var teamRosters: [TeamSide: RosterTeam]
    var shots: [TeamSide: [GamePeriod: Int]]
    var goalkeepers: [TeamSide: GoalkeeperEntry]
    var officials: Officials
    var goals: [GoalEntry]
    var penalties: [PenaltyEntry]
}

// Saves from before goalkeepers or officials were tracked have no `goalkeepers`/`officials` key.
extension GameRecord {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        teamNames = try container.decode([TeamSide: String].self, forKey: .teamNames)
        teamRosters = try container.decode([TeamSide: RosterTeam].self, forKey: .teamRosters)
        shots = try container.decode([TeamSide: [GamePeriod: Int]].self, forKey: .shots)
        goalkeepers = try container.decodeIfPresent([TeamSide: GoalkeeperEntry].self, forKey: .goalkeepers) ?? [:]
        officials = try container.decodeIfPresent(Officials.self, forKey: .officials) ?? Officials()
        goals = try container.decode([GoalEntry].self, forKey: .goals)
        penalties = try container.decode([PenaltyEntry].self, forKey: .penalties)
    }
}

/// One saved game, listed as a playlist in the sidebar.
struct SavedGame: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// False while the name is the automatic "Home vs Away · date" one, which follows the team
    /// names; renaming the save sets it.
    var isNamedByUser: Bool
    let createdAt: Date
    var updatedAt: Date
    var record: GameRecord

    init(id: UUID = UUID(), name: String, record: GameRecord, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.isNamedByUser = false
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.record = record
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isNamedByUser, createdAt, updatedAt, record
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        // Saves from before automatic naming were all named on purpose.
        isNamedByUser = try container.decodeIfPresent(Bool.self, forKey: .isNamedByUser) ?? true
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        record = try container.decode(GameRecord.self, forKey: .record)
    }

    /// e.g. "Wolves vs Bears · Oct 6, 2026".
    static func automaticName(for record: GameRecord, createdAt: Date) -> String {
        let home = record.teamNames[.home] ?? TeamSide.home.defaultName
        let away = record.teamNames[.away] ?? TeamSide.away.defaultName
        return "\(home) vs \(away) · \(createdAt.formatted(date: .abbreviated, time: .omitted))"
    }

    func goalCount(for side: TeamSide) -> Int {
        record.goals.filter { $0.team == side }.count
    }
}

extension GameStore.Game {
    var record: GameRecord {
        get {
            GameRecord(
                teamNames: teamNames,
                teamRosters: teamRosters,
                shots: shots,
                goalkeepers: goalkeepers,
                officials: officials,
                goals: goals,
                penalties: penalties
            )
        }
        set {
            teamNames = newValue.teamNames
            teamRosters = newValue.teamRosters
            shots = newValue.shots
            goalkeepers = newValue.goalkeepers
            officials = newValue.officials
            goals = newValue.goals
            penalties = newValue.penalties
        }
    }
}
