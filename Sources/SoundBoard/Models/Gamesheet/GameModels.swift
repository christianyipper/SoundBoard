import Foundation

// Game models for the Gamesheet view, ported from the ScoreCard app.

enum TeamSide: String, CaseIterable, Identifiable, Codable {
    case home
    case away

    var id: String { rawValue }

    var defaultName: String {
        switch self {
        case .home: "Home"
        case .away: "Away"
        }
    }
}

enum GamePeriod: Int, CaseIterable, Identifiable, Codable, Comparable {
    case first = 1
    case second = 2
    case third = 3
    case overtime = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .first: "1"
        case .second: "2"
        case .third: "3"
        case .overtime: "4+"
        }
    }

    var shortLabel: String { "P\(label)" }

    var fullLabel: String { "Period \(label)" }

    static func < (lhs: GamePeriod, rhs: GamePeriod) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Penalty types, split into two groups that are each single-select but combine with each other
/// (e.g. Minor + GM).
enum PenaltyType: String, CaseIterable, Identifiable, Codable {
    case minor
    case doubleMinor
    case major
    case match
    case misc
    case gameMisconduct

    var id: String { rawValue }

    var label: String {
        switch self {
        case .minor: "Minor"
        case .doubleMinor: "Double Minor"
        case .major: "Major"
        case .match: "Match"
        case .misc: "Misc"
        case .gameMisconduct: "GM"
        }
    }
}

enum PenaltyTypeRow: CaseIterable, Hashable {
    case severity
    case additional

    var title: String {
        switch self {
        case .severity: "Severity"
        case .additional: "Additional"
        }
    }

    var types: [PenaltyType] {
        switch self {
        case .severity: [.minor, .doubleMinor, .major]
        case .additional: [.match, .misc, .gameMisconduct]
        }
    }
}

extension Set where Element == PenaltyType {
    /// Picking a type clears any other selection from the same group; the other group is left
    /// alone so the two can combine.
    mutating func toggle(_ type: PenaltyType) {
        if contains(type) {
            remove(type)
        } else {
            if let row = PenaltyTypeRow.allCases.first(where: { $0.types.contains(type) }) {
                row.types.forEach { remove($0) }
            }
            insert(type)
        }
    }

    /// The selected types in display order (severity first, then additional).
    var ordered: [PenaltyType] {
        PenaltyTypeRow.allCases.flatMap { row in row.types.filter { contains($0) } }
    }
}

enum Infraction: String, CaseIterable, Identifiable, Codable {
    case tripping
    case hooking
    case slashing
    case interference
    case highSticking
    case roughing
    case holding
    case crossChecking
    case boarding
    case charging
    case tooManyMen
    case delayOfGame
    case fighting
    case headContact
    case cfb
    case slewFoot
    case instigator
    case aggressor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tripping: "Tripping"
        case .hooking: "Hooking"
        case .slashing: "Slashing"
        case .interference: "Interference"
        case .highSticking: "High-Sticking"
        case .roughing: "Roughing"
        case .holding: "Holding"
        case .crossChecking: "Cross-Checking"
        case .boarding: "Boarding"
        case .charging: "Charging"
        case .tooManyMen: "Too Many Men"
        case .delayOfGame: "Delay of Game"
        case .fighting: "Fighting"
        case .headContact: "Head Contact"
        case .cfb: "CFB"
        case .slewFoot: "Slew Foot"
        case .instigator: "Instigator"
        case .aggressor: "Aggressor"
        }
    }
}

/// The strength buttons above a side's scorer input; one must be selected before its goal can be
/// added.
enum GoalStrength: String, CaseIterable, Codable {
    case even
    case powerPlay
    case shortHanded

    var label: String {
        switch self {
        case .even: "Goal"
        case .powerPlay: "PP Goal"
        case .shortHanded: "SH Goal"
        }
    }

    /// Short tag shown in the game log; empty for an even-strength goal.
    var tag: String {
        switch self {
        case .even: ""
        case .powerPlay: "PP"
        case .shortHanded: "SH"
        }
    }
}

/// Jersey numbers are at most two digits.
enum JerseyNumber {
    static let maxDigits = 2

    static func sanitized(_ text: String) -> String {
        String(text.filter(\.isASCIIDigit).prefix(maxDigits))
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// The scorer/assist numbers typed for a side's next goal.
struct GoalDraft: Equatable {
    var scorer = ""
    var assist1 = ""
    var assist2 = ""

    var isEmpty: Bool { scorer.isEmpty && assist1.isEmpty && assist2.isEmpty }
}

/// One in-progress penalty row, before it's submitted as a `PenaltyEntry`.
struct PenaltyDraftRow: Equatable {
    var infraction: Infraction?
    var types: Set<PenaltyType> = []
    var playerNumber = ""
    /// Optional number of the player serving the penalty.
    var servedBy = ""

    static let rowsPerSide = 3

    var isComplete: Bool { infraction != nil && !types.isEmpty && !playerNumber.isEmpty }
}

/// Identifies one penalty row: which side's column and which of its rows.
struct PenaltyRowID: Equatable {
    var side: TeamSide
    var index: Int
}

struct GoalEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var team: TeamSide
    var period: GamePeriod
    var time: String
    var strength: GoalStrength
    var scorer: String
    var assist1: String?
    var assist2: String?
    /// When it was recorded, so the game log can interleave goals and penalties.
    var recordedAt: Date
    /// The team's official games played when the goal was recorded. Its scorer and assists count
    /// toward season totals until the league's posted games played moves past this. Nil for goals
    /// recorded before it was added (the game's roster snapshot stands in).
    var officialGamesPlayed: Int?

    init(
        id: UUID = UUID(),
        team: TeamSide,
        period: GamePeriod,
        time: String,
        strength: GoalStrength,
        scorer: String,
        assist1: String? = nil,
        assist2: String? = nil,
        recordedAt: Date = Date(),
        officialGamesPlayed: Int? = nil
    ) {
        self.id = id
        self.team = team
        self.period = period
        self.time = time
        self.strength = strength
        self.scorer = scorer
        self.assist1 = assist1
        self.assist2 = assist2
        self.recordedAt = recordedAt
        self.officialGamesPlayed = officialGamesPlayed
    }

    /// e.g. "PP Goal #12 (A: 5, 7)".
    var summary: String {
        let assists = [assist1, assist2].compactMap { $0 }
        return [
            strength == .even ? "Goal" : "\(strength.tag) Goal",
            "#\(scorer)",
            assists.isEmpty ? "" : "(A: \(assists.joined(separator: ", ")))"
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }
}

struct PenaltyEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var team: TeamSide
    var period: GamePeriod
    var time: String
    var infraction: Infraction
    var types: [PenaltyType]
    var playerNumber: String
    var servedBy: String?
    /// When it was recorded, so the game log can interleave goals and penalties.
    var recordedAt: Date

    init(
        id: UUID = UUID(),
        team: TeamSide,
        period: GamePeriod,
        time: String,
        infraction: Infraction,
        types: [PenaltyType],
        playerNumber: String,
        servedBy: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.team = team
        self.period = period
        self.time = time
        self.infraction = infraction
        self.types = types
        self.playerNumber = playerNumber
        self.servedBy = servedBy
        self.recordedAt = recordedAt
    }

    /// e.g. "Tripping: Minor + GM #45 (Served by #12)".
    var summary: String {
        [
            "\(infraction.label): \(types.map(\.label).joined(separator: " + "))",
            "#\(playerNumber)",
            servedBy.map { "(Served by #\($0))" } ?? ""
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }
}
