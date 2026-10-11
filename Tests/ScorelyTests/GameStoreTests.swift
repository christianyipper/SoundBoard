import XCTest
@testable import Scorely

final class GameStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testPeriodTimeFormatsTypedDigits() {
        let store = GameStore(baseDirectory: tempDirectory)

        store.setPeriodTimeText("245")
        XCTAssertEqual(store.periodTimeText, "2:45")
        XCTAssertEqual(store.stampedTime, "02:45")

        store.setPeriodTimeText("12:459")
        XCTAssertEqual(store.periodTimeText, "12:45", "colons are ignored and extra digits dropped")
        XCTAssertEqual(store.stampedTime, "12:45")

        store.setPeriodTimeText("ab")
        XCTAssertEqual(store.stampedTime, "00:00")
    }

    func testCountdownAddsTimeAndTicksToZero() {
        let store = GameStore(baseDirectory: tempDirectory)

        store.setPeriodTimeText("045")
        store.addClockTime(seconds: 30)
        XCTAssertEqual(store.periodTimeText, "1:15")
        XCTAssertEqual(store.clockState, .running)

        store.addClockTime(seconds: 60)
        XCTAssertEqual(store.periodTimeText, "2:15")

        store.setPeriodTimeText("001")
        store.addClockTime(seconds: 0)
        store.tickClock()
        XCTAssertEqual(store.stampedTime, "00:00")
        XCTAssertEqual(store.clockState, .stopped, "the countdown stops at zero")
    }

    func testEditingPausesCountdownAndTypingStopsIt() {
        let store = GameStore(baseDirectory: tempDirectory)

        store.addClockTime(seconds: 30)
        store.pauseClock()
        XCTAssertEqual(store.clockState, .paused)
        store.setPeriodTimeText("0:30")
        XCTAssertEqual(store.clockState, .paused, "the same time (e.g. select-all) doesn't stop it")
        store.resumeClock()
        XCTAssertEqual(store.clockState, .running)

        store.pauseClock()
        store.setPeriodTimeText("1200")
        XCTAssertEqual(store.clockState, .stopped)
        store.resumeClock()
        XCTAssertEqual(store.clockState, .stopped, "a typed time doesn't resume the countdown")
        XCTAssertEqual(store.periodTimeText, "12:00")
    }

    func testJerseyNumbersKeepAtMostTwoDigits() {
        XCTAssertEqual(JerseyNumber.sanitized("1a23"), "12")
        XCTAssertEqual(JerseyNumber.sanitized("v"), "")
    }

    func testShotsArePerPeriodAndNeverNegative() {
        let store = GameStore(baseDirectory: tempDirectory)
        store.addShot(for: .home)
        store.addShot(for: .home)
        store.currentPeriod = .second
        store.addShot(for: .home)
        store.addShot(for: .away, delta: -1)

        XCTAssertEqual(store.shotCount(for: .home, period: .first), 2)
        XCTAssertEqual(store.shotCount(for: .home, period: .second), 1)
        XCTAssertEqual(store.shotTotal(for: .home), 3)
        XCTAssertEqual(store.shotTotal(for: .away), 0)
    }

    func testGoalNeedsStrengthAndScorer() {
        let store = GameStore(baseDirectory: tempDirectory)
        store.updateGoalDraft(for: .home) { $0.scorer = "12" }
        XCTAssertFalse(store.canSubmitGoal(for: .home))

        store.selectGoalStrength(.powerPlay, for: .home)
        XCTAssertTrue(store.canSubmitGoal(for: .home))

        store.selectGoalStrength(.powerPlay, for: .home)
        XCTAssertFalse(store.canSubmitGoal(for: .home), "clicking the selected strength deselects it")
    }

    func testSubmitGoalStampsPeriodAndTimeAndClearsInputs() {
        let store = GameStore(baseDirectory: tempDirectory)
        store.currentPeriod = .third
        store.setPeriodTimeText("1030")
        store.selectGoalStrength(.powerPlay, for: .away)
        store.updateGoalDraft(for: .away) {
            $0.scorer = "12"
            $0.assist1 = "5"
        }

        store.submitGoal(for: .away)

        let goal = try? XCTUnwrap(store.game.goals.first)
        XCTAssertEqual(goal?.period, .third)
        XCTAssertEqual(goal?.time, "10:30")
        XCTAssertEqual(goal?.summary, "PP Goal #12 (A: 5)")
        XCTAssertEqual(store.goalCount(for: .away), 1)
        XCTAssertTrue(store.goalDraft(for: .away).isEmpty)
        XCTAssertNil(store.goalStrengths[.away])
    }

    func testSubmitPenaltiesRecordsOnlyCompleteRows() {
        let store = GameStore(baseDirectory: tempDirectory)
        store.updatePenaltyRow(side: .home, index: 0) {
            $0.infractions = [.tripping]
            $0.types.toggle(.minor)
            $0.types.toggle(.gameMisconduct)
            $0.playerNumber = "45"
            $0.servedBy = "12"
        }
        store.updatePenaltyRow(side: .home, index: 1) { $0.infractions = [.hooking] }

        store.submitPenalties(for: .home)

        XCTAssertEqual(store.game.penalties.map(\.summary), ["Tripping: Minor + GM #45 (Served by #12)"])
        XCTAssertEqual(store.penaltyRows(for: .home)[0], PenaltyDraftRow())
        XCTAssertEqual(store.penaltyRows(for: .home)[1].infractions, [.hooking], "incomplete rows are kept")
    }

    func testPickerButtonsFillTheSelectedPenaltyRow() {
        let store = GameStore(baseDirectory: tempDirectory)
        let row = PenaltyRowID(side: .away, index: 1)

        store.toggleInfraction(.tripping)
        XCTAssertEqual(store.penaltyRows(for: .away)[1], PenaltyDraftRow(), "buttons do nothing with no row selected")

        store.selectPenaltyRow(row)
        store.toggleInfraction(.tripping)
        store.toggleInfraction(.roughing)
        store.togglePenaltyType(.minor)
        store.togglePenaltyType(.gameMisconduct)
        XCTAssertEqual(store.activePenaltyDraft?.infractions, [.tripping, .roughing])
        XCTAssertEqual(store.activePenaltyDraft?.types, [.minor, .gameMisconduct])

        store.toggleInfraction(.tripping)
        XCTAssertEqual(store.activePenaltyDraft?.infractions, [.roughing], "picking a selected infraction again removes it")

        store.selectPenaltyRow(row)
        XCTAssertNil(store.activePenaltyRow, "clicking the selected row again deselects it")
    }

    func testSubmittingPenaltiesDeselectsThatSidesRow() {
        let store = GameStore(baseDirectory: tempDirectory)
        store.selectPenaltyRow(PenaltyRowID(side: .home, index: 0))
        store.toggleInfraction(.hooking)
        store.togglePenaltyType(.minor)
        store.updatePenaltyRow(side: .home, index: 0) { $0.playerNumber = "9" }

        store.submitPenalties(for: .home)

        XCTAssertNil(store.activePenaltyRow)
        XCTAssertEqual(store.game.penalties.count, 1)
    }

    func testPenaltyTypesCombineFreely() {
        var types: Set<PenaltyType> = []
        types.toggle(.misc)
        types.toggle(.minor)
        types.toggle(.major)
        types.toggle(.minor)
        XCTAssertEqual(types.ordered, [.major, .misc])
    }

    func testPenaltySavedWithSingleInfractionStillLoads() throws {
        let json = """
        {"id":"\(UUID().uuidString)","team":"home","period":1,"time":"05:00","infraction":"tripping","types":["minor"],"playerNumber":"9","recordedAt":0}
        """
        let penalty = try JSONDecoder().decode(PenaltyEntry.self, from: Data(json.utf8))
        XCTAssertEqual(penalty.infractions, [.tripping])
    }

    func testRosterTeamNamesSideAndLooksUpPlayers() {
        let store = GameStore(baseDirectory: tempDirectory)
        let player = RosterPlayer(id: 1, number: "7", name: "Sam Lee", position: "F", gp: 3, goals: 4, assists: 0, points: 4, pim: 0)
        store.selectRosterTeam(RosterTeam(id: 10, name: "Bow Valley HC", players: [player]), for: .home)

        XCTAssertEqual(store.teamName(for: .home), "Bow Valley HC")
        XCTAssertEqual(store.rosterPlayer(number: "07", side: .home)?.surname, "Lee")
        XCTAssertNil(store.rosterPlayer(number: "8", side: .home))

        store.selectGoalStrength(.even, for: .home)
        store.updateGoalDraft(for: .home) { $0.scorer = "7" }
        store.submitGoal(for: .home)
        XCTAssertEqual(store.seasonGoals(for: player, side: .home), 5)
    }

    func testRecordedGoalsAndAssistsAccumulateUntilOfficialStatsCatchUp() {
        let scorer = RosterPlayer(id: 1, number: "12", name: "Sam Lee", position: "F", gp: 5, goals: 4, assists: 1, points: 5, pim: 0)
        let helper = RosterPlayer(id: 2, number: "7", name: "Alex Kim", position: "D", gp: 5, goals: 0, assists: 2, points: 2, pim: 0)
        let team = RosterTeam(id: 10, name: "Bow Valley HC", gp: 5, players: [scorer, helper])
        let league = LeagueData(updatedAt: Date(), seasonId: nil, divisions: [RosterDivision(id: 1, name: "14U AAA", teams: [team])])
        let store = GameStore(baseDirectory: tempDirectory)

        func score(assist: String? = nil) {
            store.selectGoalStrength(.even, for: .home)
            store.updateGoalDraft(for: .home) {
                $0.scorer = "12"
                $0.assist1 = assist ?? ""
            }
            store.submitGoal(for: .home, league: league)
        }

        store.selectRosterTeam(team, for: .home)
        score(assist: "07")
        score()
        store.newGame()
        store.selectRosterTeam(team, for: .home)
        score(assist: "7")

        XCTAssertEqual(store.pendingStats(for: team)["12"], GameStore.PendingStats(goals: 3, assists: 0))
        XCTAssertEqual(store.pendingStats(for: team)["7"], GameStore.PendingStats(goals: 0, assists: 2))
        XCTAssertEqual(store.seasonGoals(for: scorer, side: .home, league: league), 7, "goals carry over into the next game")

        store.flush()
        XCTAssertEqual(GameStore(baseDirectory: tempDirectory).pendingStats(for: team)["12"]?.goals, 3, "kept across launches")

        var updated = team
        updated.gp = 7
        updated.players[0].goals = 7
        XCTAssertTrue(store.pendingStats(for: updated).isEmpty, "a refresh with the games posted replaces the local counts")
        XCTAssertEqual(store.pendingStats(for: team)["12"]?.goals, 3, "a refresh without new games keeps them")
    }

    func testSeasonGoalNumberCountsUpFromScrapedGoalsUntilTheNextGameIsPosted() {
        let player = RosterPlayer(id: 1, number: "55", name: "Sam Lee", position: "F", gp: 10, goals: 8, assists: 0, points: 8, pim: 0)
        let team = RosterTeam(id: 10, name: "Bow Valley HC", gp: 10, players: [player])
        func league(_ team: RosterTeam) -> LeagueData {
            LeagueData(updatedAt: Date(), seasonId: nil, divisions: [RosterDivision(id: 1, name: "14U AAA", teams: [team])])
        }
        let store = GameStore(baseDirectory: tempDirectory)
        store.selectRosterTeam(team, for: .home)

        func score(_ current: RosterTeam = team) -> GoalEntry {
            store.selectGoalStrength(.even, for: .home)
            store.updateGoalDraft(for: .home) { $0.scorer = "55" }
            store.submitGoal(for: .home, league: league(current))
            return store.game.goals.last!
        }

        let first = score()
        XCTAssertEqual(store.seasonGoalNumber(for: first, league: league(team)), 9)
        let second = score()
        XCTAssertEqual(store.seasonGoalNumber(for: first, league: league(team)), 9, "an earlier goal keeps its number")
        XCTAssertEqual(store.seasonGoalNumber(for: second, league: league(team)), 10)

        store.newGame()
        store.selectRosterTeam(team, for: .home)
        XCTAssertEqual(store.seasonGoalNumber(for: score(), league: league(team)), 11, "carries into the next game")

        var posted = team
        posted.gp = 12
        posted.players[0].goals = 11
        store.newGame()
        store.selectRosterTeam(posted, for: .home)
        XCTAssertEqual(store.seasonGoalNumber(for: score(posted), league: league(posted)), 12, "a scrape with the games posted replaces the local count")
    }

    func testDeletingASaveDropsItsGoalsFromSeasonCounts() {
        let player = RosterPlayer(id: 1, number: "55", name: "Sam Lee", position: "F", gp: 10, goals: 8, assists: 0, points: 8, pim: 0)
        let team = RosterTeam(id: 10, name: "Bow Valley HC", gp: 10, players: [player])
        let store = GameStore(baseDirectory: tempDirectory)

        func playGame(goals: Int) -> UUID {
            store.newGame()
            store.selectRosterTeam(team, for: .home)
            for _ in 0..<goals {
                store.selectGoalStrength(.even, for: .home)
                store.updateGoalDraft(for: .home) { $0.scorer = "55" }
                store.submitGoal(for: .home)
            }
            return store.activeSaveID!
        }

        let first = playGame(goals: 2)
        let second = playGame(goals: 1)
        XCTAssertEqual(store.seasonGoals(for: player, side: .home), 11)

        store.deleteSave(first)
        XCTAssertEqual(store.seasonGoals(for: player, side: .home), 9, "an older game's goals go with it")

        store.deleteSave(second)
        XCTAssertTrue(store.pendingStats(for: team).isEmpty, "deleting the live game's save clears its goals too")

        store.flush()
        XCTAssertTrue(GameStore(baseDirectory: tempDirectory).pendingStats(for: team).isEmpty, "stays gone after a relaunch")
    }

    func testCustomTeamNameFallsBackToDefaultWhenEmpty() {
        let store = GameStore(baseDirectory: tempDirectory)
        store.setTeamName("  ", for: .away)
        XCTAssertEqual(store.teamName(for: .away), "Away")
    }

    func testGamePersistsAndNewGameClearsIt() {
        let store = GameStore(baseDirectory: tempDirectory)
        store.setTeamName("Wolves", for: .home)
        store.addShot(for: .away)
        store.flush()

        let reloaded = GameStore(baseDirectory: tempDirectory)
        XCTAssertEqual(reloaded.teamName(for: .home), "Wolves")
        XCTAssertEqual(reloaded.shotTotal(for: .away), 1)

        reloaded.newGame()
        XCTAssertEqual(reloaded.game, GameStore.Game())
    }

    func testFirstChangeSavesTheGameAutomaticallyAndKeepsItInSync() {
        let store = GameStore(baseDirectory: tempDirectory)
        XCTAssertTrue(store.savedGames.isEmpty, "a blank game isn't saved")

        store.setTeamName("Wolves", for: .home)
        let save = try! XCTUnwrap(store.savedGames.first)
        XCTAssertEqual(store.activeSaveID, save.id)
        XCTAssertTrue(save.name.hasPrefix("Wolves vs Away"))

        store.setTeamName("Bears", for: .away)
        store.addShot(for: .home)
        XCTAssertEqual(store.savedGames.count, 1)
        XCTAssertEqual(store.savedGames[0].record.shots[.home]?[.first], 1, "the active save follows the live game")
        XCTAssertTrue(store.savedGames[0].name.hasPrefix("Wolves vs Bears"), "automatic names follow the teams")

        store.renameSave(save.id, to: "Final")
        store.setTeamName("Lions", for: .away)
        XCTAssertEqual(store.savedGames[0].name, "Final", "a chosen name sticks")
    }

    func testLoadingASaveRestoresItsGamesheetInfoOnly() {
        let store = GameStore(baseDirectory: tempDirectory)
        store.setTeamName("Wolves", for: .home)
        store.addShot(for: .away)
        let firstID = try! XCTUnwrap(store.activeSaveID)

        store.newGame()
        let secondID = try! XCTUnwrap(store.activeSaveID)
        XCTAssertNotEqual(secondID, firstID)
        XCTAssertEqual(store.savedGames.map(\.id), [secondID, firstID], "a new game is listed right away, newest first")
        XCTAssertEqual(store.savedGames[1].record.teamNames[.home], "Wolves", "starting over leaves the save alone")
        store.setTeamName("Bears", for: .home)
        XCTAssertEqual(store.savedGames.count, 2)

        store.currentPeriod = .third
        store.setPeriodTimeText("1245")
        store.loadSave(firstID)
        XCTAssertEqual(store.activeSaveID, firstID)
        XCTAssertEqual(store.teamName(for: .home), "Wolves")
        XCTAssertEqual(store.shotTotal(for: .away), 1)
        XCTAssertEqual(store.currentPeriod, .first, "period and clock aren't part of a save")
        XCTAssertEqual(store.periodTimeText, "")
        XCTAssertEqual(store.savedGames.first { $0.id != firstID }?.record.teamNames[.home], "Bears")
    }

    func testRenameAndDeleteSaves() {
        let store = GameStore(baseDirectory: tempDirectory)
        store.addShot(for: .home)
        let id = try! XCTUnwrap(store.activeSaveID)

        store.renameSave(id, to: "  Playoff Game 1 ")
        XCTAssertEqual(store.savedGames[0].name, "Playoff Game 1")
        store.renameSave(id, to: "   ")
        XCTAssertEqual(store.savedGames[0].name, "Playoff Game 1", "blank names are ignored")

        store.deleteSave(id)
        XCTAssertTrue(store.savedGames.isEmpty)
        XCTAssertNil(store.activeSaveID)
        XCTAssertEqual(store.shotTotal(for: .home), 0, "deleting the active save clears the sheet")
    }

    func testDeletingTheActiveSaveOpensTheNewestRemainingOne() {
        let store = GameStore(baseDirectory: tempDirectory)
        store.setTeamName("Wolves", for: .home)
        let firstID = try! XCTUnwrap(store.activeSaveID)
        store.newGame()
        store.setTeamName("Bears", for: .home)

        store.deleteSave(try! XCTUnwrap(store.activeSaveID))

        XCTAssertEqual(store.activeSaveID, firstID)
        XCTAssertEqual(store.teamName(for: .home), "Wolves")
    }

    func testOfficialsAreSavedWithTheGame() {
        let store = GameStore(baseDirectory: tempDirectory)
        store.setOfficialName("Pat Doe", role: .referee, index: 1)
        store.setOfficialName("Kim Fox", role: .linesperson, index: 0)
        let id = try! XCTUnwrap(store.activeSaveID)

        store.newGame()
        XCTAssertEqual(store.game.officials, Officials())
        store.loadSave(id)
        XCTAssertEqual(store.officialName(.referee, index: 1), "Pat Doe")
        XCTAssertEqual(store.officialName(.linesperson, index: 0), "Kim Fox")
    }

    func testSavesPersist() {
        let store = GameStore(baseDirectory: tempDirectory)
        store.setTeamName("Wolves", for: .home)
        store.flush()

        let reloaded = GameStore(baseDirectory: tempDirectory)
        XCTAssertEqual(reloaded.savedGames, store.savedGames)
        XCTAssertEqual(reloaded.activeSaveID, store.activeSaveID)
    }

    func testReturnKeyMovesThroughGoalAndPenaltyFields() {
        XCTAssertEqual(GamesheetField.goal(.home, .scorer).next, .goal(.home, .assist1))
        XCTAssertNil(GamesheetField.goal(.home, .assist2).next)
        XCTAssertEqual(GamesheetField.penaltyNumber(.away, 2).next, .servedBy(.away, 2))
        XCTAssertNil(GamesheetField.time.next)
        XCTAssertEqual(GamesheetField.goalie(.home).next, .goalieSub(.home))
        XCTAssertEqual(GamesheetField.goalieSub(.home).next, .goalieSubTime(.home))
        XCTAssertNil(GamesheetField.goalieSubTime(.home).next)
    }

    func testGoalkeepersAreSavedWithTheGame() throws {
        let store = GameStore(baseDirectory: tempDirectory)
        store.updateGoalkeepers(for: .home) { $0.goalie = JerseyNumber.sanitized("31") }
        store.updateGoalkeepers(for: .home) { $0.sub = "1" }
        store.setGoalieSubTimeText("8:30", for: .home)
        XCTAssertEqual(store.goalieSubTimeText(for: .home), "8:30")
        XCTAssertEqual(store.goalkeepers(for: .away), GoalkeeperEntry())

        let saveID = try XCTUnwrap(store.activeSaveID, "entering a goalie starts a save")
        store.flush()
        let reloaded = GameStore(baseDirectory: tempDirectory)
        XCTAssertEqual(reloaded.goalkeepers(for: .home), GoalkeeperEntry(goalie: "31", sub: "1", subTimeDigits: "830"))

        reloaded.newGame()
        XCTAssertEqual(reloaded.goalkeepers(for: .home), GoalkeeperEntry())
        reloaded.loadSave(saveID)
        XCTAssertEqual(reloaded.goalkeepers(for: .home).goalie, "31")
    }

    func testGamesSavedBeforeGoalkeepersStillLoad() throws {
        var game = GameStore.Game()
        game.teamNames[.home] = "Wolves"
        let oldGame = try withoutGoalkeepers(JSONEncoder().encode(game))
        let decoded = try JSONDecoder().decode(GameStore.Game.self, from: oldGame)
        XCTAssertEqual(decoded.teamNames[.home], "Wolves")
        XCTAssertTrue(decoded.goalkeepers.isEmpty)

        let oldRecord = try withoutGoalkeepers(JSONEncoder().encode(game.record))
        XCTAssertTrue(try JSONDecoder().decode(GameRecord.self, from: oldRecord).goalkeepers.isEmpty)
    }

    private func withoutGoalkeepers(_ data: Data) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "goalkeepers"))
        return try JSONSerialization.data(withJSONObject: object)
    }

    @MainActor
    func testRefreshRostersLoadsAndCachesLeague() async throws {
        let json = """
        {"updatedAt":"2026-09-29T15:38:16.105Z","divisions":[{"id":1,"name":"14U AAA","teams":[{"id":2,"name":"Bow Valley HC","players":[]}]}]}
        """
        let source = tempDirectory.appendingPathComponent("published.json")
        try Data(json.utf8).write(to: source)

        let store = RosterStore(baseDirectory: tempDirectory, sourceURL: source, refreshOnLaunch: false)
        XCTAssertNil(store.league)
        await store.refresh()
        XCTAssertEqual(store.league?.divisions.first?.teams.first?.name, "Bow Valley HC")

        let missing = tempDirectory.appendingPathComponent("missing.json")
        XCTAssertNotNil(RosterStore(baseDirectory: tempDirectory, sourceURL: missing, refreshOnLaunch: false).league,
                        "downloaded rosters are kept for next launch")
    }

    @MainActor
    func testRefreshingInvalidRostersKeepsExistingLeague() async throws {
        let bad = tempDirectory.appendingPathComponent("bad.json")
        try Data("{}".utf8).write(to: bad)
        let store = RosterStore(baseDirectory: tempDirectory, sourceURL: bad, refreshOnLaunch: false)
        await store.refresh()
        XCTAssertNil(store.league)
        XCTAssertFalse(store.isRefreshing)
    }
}
