import Foundation

/// The wording of goals and penalties in the Call tab: a compact "Sheet" line, or a multi-line
/// "Call" script for reading them out.
enum CallText {
    // MARK: - Sheet

    /// e.g. "12:45 - #12, #5, #7" (scorer, then assists).
    static func sheetGoal(_ goal: GoalEntry) -> String {
        let numbers = ([goal.scorer] + [goal.assist1, goal.assist2].compactMap { $0 }).map { "#\($0)" }
        return "\(goal.time) - \(numbers.joined(separator: ", "))"
    }

    /// e.g. "08:10 - #45, (Major and Game Misconduct) Fighting".
    static func sheetPenalty(_ penalty: PenaltyEntry) -> String {
        let types = penalty.types.map(\.fullName).joined(separator: " and ")
        return "\(penalty.time) - #\(penalty.playerNumber), (\(types)) \(penalty.infraction.fullName)"
    }

    // MARK: - Call

    /// One line per sentence, e.g.
    /// "Wolves Goal.
    ///  His third of the season, scored by number 12, John Smith.
    ///  Assisted by number 5, Jane Jones.
    ///  And by number 7, Bob Brown.
    ///  Time of the goal, 12:45 in the first period."
    /// `seasonGoal` is which of the scorer's season goals this was (nil leaves it out), and
    /// `name` looks up a jersey number's player name (nil leaves the name out).
    static func callGoal(
        _ goal: GoalEntry,
        teamName: String,
        seasonGoal: Int?,
        name: (String) -> String?
    ) -> String {
        let assists = [goal.assist1, goal.assist2].compactMap { $0 }
        let scored = (["scored"] + (assists.isEmpty ? ["unassisted"] : []) + (goal.strength.callPhrase.map { [$0] } ?? []))
            .joined(separator: " ")
        let scorer = "\(scored) by number \(player(goal.scorer, name: name))."
        var lines = [
            "\(teamName) Goal.",
            seasonGoal.map { "His \(ordinal($0)) of the season, \(scorer)" } ?? scorer.prefix(1).uppercased() + scorer.dropFirst()
        ]
        for (index, assist) in assists.enumerated() {
            lines.append("\(index == 0 ? "Assisted" : "And") by number \(player(assist, name: name)).")
        }
        lines.append("Time of the goal, \(goal.time) in \(periodPhrase(goal.period)).")
        return lines.joined(separator: "\n")
    }

    /// e.g. "Wolves penalty to number 45, John Smith, a Major penalty and a Game Misconduct for
    /// Fighting, served by number 12, Jim Lee.
    ///  Time of the penalty, 08:10 in the second period."
    static func callPenalty(_ penalty: PenaltyEntry, teamName: String, name: (String) -> String?) -> String {
        let length = penalty.types.map(\.callPhrase).joined(separator: " and ")
        let servedBy = penalty.servedBy.map { ", served by number \(player($0, name: name))" } ?? ""
        return [
            "\(teamName) penalty to number \(player(penalty.playerNumber, name: name)), \(length) for \(penalty.infraction.fullName)\(servedBy).",
            "Time of the penalty, \(penalty.time) in \(periodPhrase(penalty.period))."
        ]
        .joined(separator: "\n")
    }

    /// "12, John Smith", or just "12" when there's no name.
    private static func player(_ number: String, name: (String) -> String?) -> String {
        name(number).map { "\(number), \($0)" } ?? number
    }

    /// "the first period" … "the third period", or "overtime".
    static func periodPhrase(_ period: GamePeriod) -> String {
        period == .overtime ? "overtime" : "the \(ordinal(period.rawValue)) period"
    }

    // MARK: - Ordinals

    private static let smallOrdinals = [
        "", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
        "eighteenth", "nineteenth"
    ]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let tensOrdinals = [
        "", "", "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth"
    ]

    /// Spelled out up to 99 ("first", "twenty-second"), then "100th" and so on.
    static func ordinal(_ number: Int) -> String {
        switch number {
        case 1..<20:
            return smallOrdinals[number]
        case 20..<100:
            let ones = number % 10
            return ones == 0 ? tensOrdinals[number / 10] : "\(tens[number / 10])-\(smallOrdinals[ones])"
        default:
            let formatter = NumberFormatter()
            formatter.numberStyle = .ordinal
            return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
        }
    }
}

extension GoalStrength {
    /// How the goal was scored, as read out in a call; nil at even strength.
    var callPhrase: String? {
        switch self {
        case .even: nil
        case .powerPlay: "on the powerplay"
        case .shortHanded: "shorthanded"
        }
    }
}

extension PenaltyType {
    /// Spelled out for the Call tab's Sheet lines.
    var fullName: String {
        switch self {
        case .minor: "Minor"
        case .doubleMinor: "Double Minor"
        case .major: "Major"
        case .match: "Match"
        case .misc: "Misconduct"
        case .gameMisconduct: "Game Misconduct"
        }
    }

    /// How long the penalty is, as read out in a call.
    var callPhrase: String {
        switch self {
        case .minor: "2 minutes"
        case .doubleMinor: "4 minutes"
        case .major: "a Major penalty"
        case .match: "a Match penalty"
        case .misc: "a 10 minute Misconduct"
        case .gameMisconduct: "a Game Misconduct"
        }
    }
}
