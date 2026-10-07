import XCTest
@testable import SoundBoard

final class CallTextTests: XCTestCase {
    private let names = ["12": "John Smith", "5": "Jane Jones", "45": "Bob Brown"]

    private func name(_ number: String) -> String? { names[number] }

    func testSheetGoalListsScorerAndAssists() {
        let goal = GoalEntry(team: .home, period: .first, time: "12:45", strength: .powerPlay, scorer: "12", assist1: "5", assist2: "7")
        XCTAssertEqual(CallText.sheetGoal(goal), "12:45 - G:12, A:5, A:7")

        let unassisted = GoalEntry(team: .home, period: .first, time: "03:00", strength: .even, scorer: "9")
        XCTAssertEqual(CallText.sheetGoal(unassisted), "03:00 - G:9")
    }

    func testSheetPenaltyJoinsTypes() {
        let penalty = PenaltyEntry(team: .away, period: .second, time: "08:10", infraction: .fighting, types: [.major, .gameMisconduct], playerNumber: "45")
        XCTAssertEqual(CallText.sheetPenalty(penalty), "08:10 - #45, (Major and Game Misconduct) Fighting")
    }

    func testCallGoal() {
        let goal = GoalEntry(team: .home, period: .first, time: "12:45", strength: .even, scorer: "12", assist1: "5", assist2: "7")
        XCTAssertEqual(
            CallText.callGoal(goal, teamName: "Wolves", seasonGoal: 3, name: name),
            """
            Wolves Goal.
            His third of the season, scored by number 12, John Smith.
            Assisted by number 5, Jane Jones.
            And by number 7.
            Time of the goal, 12:45 in the first period.
            """
        )
    }

    func testCallGoalWithoutRosterOrAssists() {
        let goal = GoalEntry(team: .home, period: .overtime, time: "01:02", strength: .even, scorer: "99")
        XCTAssertEqual(
            CallText.callGoal(goal, teamName: "Wolves", seasonGoal: nil, name: name),
            """
            Wolves Goal.
            Scored unassisted by number 99.
            Time of the goal, 01:02 in overtime.
            """
        )
    }

    func testCallGoalStrength() {
        let powerPlay = GoalEntry(team: .home, period: .second, time: "05:00", strength: .powerPlay, scorer: "12", assist1: "5")
        XCTAssertTrue(CallText.callGoal(powerPlay, teamName: "Wolves", seasonGoal: 1, name: name)
            .contains("His first of the season, scored on the powerplay by number 12, John Smith."))

        let shortHanded = GoalEntry(team: .home, period: .second, time: "05:00", strength: .shortHanded, scorer: "12")
        XCTAssertTrue(CallText.callGoal(shortHanded, teamName: "Wolves", seasonGoal: 2, name: name)
            .contains("His second of the season, scored unassisted shorthanded by number 12, John Smith."))
    }

    func testCallPenaltyServedBy() {
        let penalty = PenaltyEntry(team: .away, period: .first, time: "02:00", infraction: .tooManyMen, types: [.minor], playerNumber: "45", servedBy: "5")
        XCTAssertEqual(
            CallText.callPenalty(penalty, teamName: "Bears", name: name),
            """
            Bears penalty to number 45, Bob Brown, 2 minutes for Too Many Men, served by number 5, Jane Jones.
            Time of the penalty, 02:00 in the first period.
            """
        )
    }

    func testCallPenalty() {
        let minor = PenaltyEntry(team: .away, period: .third, time: "04:20", infraction: .tripping, types: [.minor], playerNumber: "45")
        XCTAssertEqual(
            CallText.callPenalty(minor, teamName: "Bears", name: name),
            """
            Bears penalty to number 45, Bob Brown, 2 minutes for Tripping.
            Time of the penalty, 04:20 in the third period.
            """
        )

        let major = PenaltyEntry(team: .away, period: .second, time: "08:10", infraction: .fighting, types: [.major, .gameMisconduct], playerNumber: "45")
        XCTAssertEqual(
            CallText.callPenalty(major, teamName: "Bears", name: name),
            """
            Bears penalty to number 45, Bob Brown, a Major penalty and a Game Misconduct for Fighting.
            Time of the penalty, 08:10 in the second period.
            """
        )
    }

    func testOrdinals() {
        XCTAssertEqual(CallText.ordinal(1), "first")
        XCTAssertEqual(CallText.ordinal(12), "twelfth")
        XCTAssertEqual(CallText.ordinal(20), "twentieth")
        XCTAssertEqual(CallText.ordinal(22), "twenty-second")
        XCTAssertEqual(CallText.ordinal(101), "101st")
    }
}
