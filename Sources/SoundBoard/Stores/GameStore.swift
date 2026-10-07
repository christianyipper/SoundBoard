import Foundation

/// Owns the live game shown in the Gamesheet view (ported from the ScoreCard app): team names and
/// rosters, the current period and clock time, shots per period, and the recorded goals and
/// penalties. The recorded game is saved to disk so it survives a relaunch mid-game; the
/// in-progress goal/penalty inputs are not. It also keeps the Game Log: named saves of past games.
/// Saving is automatic: the first change to a blank game creates a save for it, which becomes the
/// active session, and every later change is copied into that save as it happens.
final class GameStore: ObservableObject {
    struct Game: Codable, Equatable {
        var teamNames: [TeamSide: String] = [.home: TeamSide.home.defaultName, .away: TeamSide.away.defaultName]
        var teamRosters: [TeamSide: RosterTeam] = [:]
        var currentPeriod: GamePeriod = .first
        /// Up to four digits typed into the time field, e.g. "1245" for 12:45.
        var periodTimeDigits = ""
        var shots: [TeamSide: [GamePeriod: Int]] = [:]
        var goals: [GoalEntry] = []
        var penalties: [PenaltyEntry] = []
    }

    @Published private(set) var game: Game {
        didSet {
            syncActiveSave()
            scheduleSave()
        }
    }

    /// The Game Log, newest first.
    @Published private(set) var savedGames: [SavedGame] = []
    /// The save the live game belongs to; nil while it's unsaved.
    @Published private(set) var activeSaveID: UUID?

    @Published var goalDrafts: [TeamSide: GoalDraft] = [:]
    @Published var goalStrengths: [TeamSide: GoalStrength] = [:]
    @Published var penaltyDrafts: [TeamSide: [PenaltyDraftRow]] = GameStore.emptyPenaltyDrafts()
    /// The penalty row the infraction/type buttons apply to. While set, the opposite side's
    /// column shows those buttons in place of its penalty rows.
    @Published var activePenaltyRow: PenaltyRowID?

    private let fileURL: URL
    private let savesURL: URL
    private var saveWorkItem: DispatchWorkItem?

    private struct SavesFile: Codable {
        var saves: [SavedGame]
        var activeSaveID: UUID?
    }

    init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent("gamesheet.json")
        savesURL = baseDirectory.appendingPathComponent("gamesheet-saves.json")
        game = Self.load(from: fileURL) ?? Game()
        if let file = Self.loadSaves(from: savesURL) {
            savedGames = file.saves
            activeSaveID = file.activeSaveID.flatMap { id in file.saves.contains { $0.id == id } ? id : nil }
        }
        // A game in progress from before automatic saving gets its save now.
        syncActiveSave()
    }

    private static func emptyPenaltyDrafts() -> [TeamSide: [PenaltyDraftRow]] {
        Dictionary(uniqueKeysWithValues: TeamSide.allCases.map {
            ($0, Array(repeating: PenaltyDraftRow(), count: PenaltyDraftRow.rowsPerSide))
        })
    }

    // MARK: - Teams

    func teamName(for side: TeamSide) -> String {
        game.teamNames[side] ?? side.defaultName
    }

    /// An empty name falls back to the side's default ("Home"/"Away").
    func setTeamName(_ name: String, for side: TeamSide) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        game.teamNames[side] = trimmed.isEmpty ? side.defaultName : trimmed
    }

    /// Picks `team` as `side`'s roster and names the side after it; nil clears the roster and
    /// leaves the name as it was.
    func selectRosterTeam(_ team: RosterTeam?, for side: TeamSide) {
        game.teamRosters[side] = team
        if let team { game.teamNames[side] = team.name }
    }

    /// The player wearing `number` on `side`'s roster, preferring `league`'s copy of the team
    /// when it's newer than the one picked. Nil when the side has no roster or no such player.
    func rosterPlayer(number: String, side: TeamSide, league: LeagueData? = nil) -> RosterPlayer? {
        rosterTeam(for: side, league: league)?.player(number: number)
    }

    /// `side`'s picked team, preferring `league`'s copy when it's newer than the one picked.
    func rosterTeam(for side: TeamSide, league: LeagueData? = nil) -> RosterTeam? {
        guard let picked = game.teamRosters[side] else { return nil }
        return league?.team(id: picked.id) ?? picked
    }

    func hasRoster(_ side: TeamSide) -> Bool {
        game.teamRosters[side] != nil
    }

    /// Goals and assists recorded in the Gamesheet that a team's official stats don't include yet.
    struct PendingStats: Equatable {
        var goals = 0
        var assists = 0
    }

    /// Goals and assists recorded for `team` (pass the league's latest copy) across every game in
    /// the Game Log, keyed by normalized jersey number. A goal stays pending until the league's
    /// posted games played for the team moves past what it was when the goal was recorded, which
    /// is when a scraper refresh brings in the official stats for that game.
    func pendingStats(for team: RosterTeam) -> [String: PendingStats] {
        var stats: [String: PendingStats] = [:]
        let records = savedGames.map(\.record) + (activeSaveID == nil ? [game.record] : [])
        for record in records {
            for (side, picked) in record.teamRosters where picked.id == team.id {
                for goal in record.goals where goal.team == side {
                    guard team.gamesPlayed <= goal.officialGamesPlayed ?? picked.gamesPlayed else { continue }
                    stats[RosterPlayer.normalized(goal.scorer), default: PendingStats()].goals += 1
                    for assist in [goal.assist1, goal.assist2].compactMap({ $0 }) {
                        stats[RosterPlayer.normalized(assist), default: PendingStats()].assists += 1
                    }
                }
            }
        }
        return stats
    }

    /// Season goals for a scorer: the league's posted total plus goals recorded here since.
    func seasonGoals(for player: RosterPlayer, side: TeamSide, league: LeagueData? = nil) -> Int {
        guard let team = rosterTeam(for: side, league: league) else { return player.goals }
        return player.goals + (pendingStats(for: team)[RosterPlayer.normalized(player.number)]?.goals ?? 0)
    }

    /// Which of its scorer's season goals `goal` was, e.g. 9 for a player the league last posted
    /// with 8: the scorer's season goals (which count this game's) less the goals they've scored
    /// in this game since. Nil when the scorer isn't on the side's roster.
    func seasonGoalNumber(for goal: GoalEntry, league: LeagueData? = nil) -> Int? {
        guard let scorer = rosterPlayer(number: goal.scorer, side: goal.team, league: league) else { return nil }
        let key = RosterPlayer.normalized(goal.scorer)
        let later = game.goals.filter {
            $0.team == goal.team && RosterPlayer.normalized($0.scorer) == key && $0.recordedAt > goal.recordedAt
        }.count
        let number = seasonGoals(for: scorer, side: goal.team, league: league) - later
        return number > 0 ? number : nil
    }

    // MARK: - Period & time

    var currentPeriod: GamePeriod {
        get { game.currentPeriod }
        set { game.currentPeriod = newValue }
    }

    /// The time field's text: digits with a colon before the last two once there are more than
    /// two ("245" → "2:45", "1245" → "12:45").
    var periodTimeText: String {
        let digits = game.periodTimeDigits
        guard digits.count > 2 else { return digits }
        return "\(digits.dropLast(2)):\(digits.suffix(2))"
    }

    /// Keeps only the first four digits of whatever was typed (so "12:45" and "1245" both work).
    func setPeriodTimeText(_ text: String) {
        game.periodTimeDigits = String(text.filter(\.isASCIIDigit).prefix(4))
    }

    /// The time stamped onto goals and penalties, always MM:SS ("245" → "02:45").
    var stampedTime: String {
        let padded = String(repeating: "0", count: 4 - game.periodTimeDigits.count) + game.periodTimeDigits
        return "\(padded.prefix(2)):\(padded.suffix(2))"
    }

    // MARK: - Shots

    func shotCount(for side: TeamSide, period: GamePeriod) -> Int {
        game.shots[side]?[period] ?? 0
    }

    func shotTotal(for side: TeamSide) -> Int {
        GamePeriod.allCases.reduce(0) { $0 + shotCount(for: side, period: $1) }
    }

    /// Adjusts the current period's shots, never going below zero.
    func addShot(for side: TeamSide, delta: Int = 1) {
        let updated = max(0, shotCount(for: side, period: game.currentPeriod) + delta)
        game.shots[side, default: [:]][game.currentPeriod] = updated
    }

    // MARK: - Goals

    func goalCount(for side: TeamSide) -> Int {
        game.goals.filter { $0.team == side }.count
    }

    func goalDraft(for side: TeamSide) -> GoalDraft {
        goalDrafts[side] ?? GoalDraft()
    }

    func updateGoalDraft(for side: TeamSide, _ change: (inout GoalDraft) -> Void) {
        var draft = goalDraft(for: side)
        change(&draft)
        goalDrafts[side] = draft
    }

    /// Clicking a strength selects it; clicking the selected one deselects it.
    func selectGoalStrength(_ strength: GoalStrength, for side: TeamSide) {
        goalStrengths[side] = goalStrengths[side] == strength ? nil : strength
    }

    /// A goal needs both a strength and a scorer.
    func canSubmitGoal(for side: TeamSide) -> Bool {
        goalStrengths[side] != nil && !goalDraft(for: side).scorer.isEmpty
    }

    /// Records `side`'s goal, stamped with the current period and time (and the team's official
    /// games played, from `league` when given), then clears its inputs.
    func submitGoal(for side: TeamSide, league: LeagueData? = nil) {
        guard canSubmitGoal(for: side), let strength = goalStrengths[side] else { return }
        let draft = goalDraft(for: side)
        game.goals.append(GoalEntry(
            team: side,
            period: game.currentPeriod,
            time: stampedTime,
            strength: strength,
            scorer: draft.scorer,
            assist1: draft.assist1.isEmpty ? nil : draft.assist1,
            assist2: draft.assist2.isEmpty ? nil : draft.assist2,
            officialGamesPlayed: rosterTeam(for: side, league: league)?.gamesPlayed
        ))
        goalDrafts[side] = GoalDraft()
        goalStrengths[side] = nil
    }

    func deleteGoal(_ id: UUID) {
        game.goals.removeAll { $0.id == id }
    }

    // MARK: - Penalties

    func penaltyRows(for side: TeamSide) -> [PenaltyDraftRow] {
        penaltyDrafts[side] ?? []
    }

    func updatePenaltyRow(side: TeamSide, index: Int, _ change: (inout PenaltyDraftRow) -> Void) {
        guard penaltyDrafts[side]?.indices.contains(index) == true else { return }
        change(&penaltyDrafts[side]![index])
    }

    /// Clicking a row activates it; clicking the active row again deactivates it.
    func selectPenaltyRow(_ row: PenaltyRowID) {
        activePenaltyRow = activePenaltyRow == row ? nil : row
    }

    /// Picking the active row's current infraction again clears it.
    func setInfraction(_ infraction: Infraction) {
        guard let row = activePenaltyRow else { return }
        updatePenaltyRow(side: row.side, index: row.index) {
            $0.infraction = $0.infraction == infraction ? nil : infraction
        }
    }

    func togglePenaltyType(_ type: PenaltyType) {
        guard let row = activePenaltyRow else { return }
        updatePenaltyRow(side: row.side, index: row.index) { $0.types.toggle(type) }
    }

    var activePenaltyDraft: PenaltyDraftRow? {
        activePenaltyRow.map { penaltyRows(for: $0.side)[$0.index] }
    }

    func canSubmitPenalties(for side: TeamSide) -> Bool {
        penaltyRows(for: side).contains(where: \.isComplete)
    }

    /// Records every complete row on `side`, stamped with the current period and time, and
    /// empties those rows. Incomplete rows are left as they are.
    func submitPenalties(for side: TeamSide) {
        var rows = penaltyRows(for: side)
        for index in rows.indices where rows[index].isComplete {
            let row = rows[index]
            guard let infraction = row.infraction else { continue }
            game.penalties.append(PenaltyEntry(
                team: side,
                period: game.currentPeriod,
                time: stampedTime,
                infraction: infraction,
                types: row.types.ordered,
                playerNumber: row.playerNumber,
                servedBy: row.servedBy.isEmpty ? nil : row.servedBy
            ))
            rows[index] = PenaltyDraftRow()
        }
        penaltyDrafts[side] = rows
        if activePenaltyRow?.side == side { activePenaltyRow = nil }
    }

    func deletePenalty(_ id: UUID) {
        game.penalties.removeAll { $0.id == id }
    }

    // MARK: - Game

    /// Clears everything back to a blank, unsaved game. The active save (if any) keeps its contents.
    func newGame() {
        activeSaveID = nil
        game = Game()
        goalDrafts = [:]
        goalStrengths = [:]
        penaltyDrafts = Self.emptyPenaltyDrafts()
        activePenaltyRow = nil
    }

    // MARK: - Game Log

    /// Replaces the live game with a save's contents and makes it the active session. The period
    /// and clock start over, and any half-typed goal/penalty inputs are cleared.
    func loadSave(_ id: UUID) {
        guard let save = savedGames.first(where: { $0.id == id }) else { return }
        activeSaveID = id
        var loaded = Game()
        loaded.record = save.record
        game = loaded
        goalDrafts = [:]
        goalStrengths = [:]
        penaltyDrafts = Self.emptyPenaltyDrafts()
        activePenaltyRow = nil
    }

    /// An empty name keeps the old one.
    func renameSave(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = savedGames.firstIndex(where: { $0.id == id }) else { return }
        savedGames[index].name = trimmed
        savedGames[index].isNamedByUser = true
        scheduleSave()
    }

    /// Deleting the active save also clears the gamesheet (otherwise the next change would just
    /// save it again).
    func deleteSave(_ id: UUID) {
        savedGames.removeAll { $0.id == id }
        if activeSaveID == id {
            newGame()
        }
        scheduleSave()
    }

    private var activeSaveIndex: Int? {
        activeSaveID.flatMap { id in savedGames.firstIndex { $0.id == id } }
    }

    /// Copies the live game into the active save whenever the saved parts of it change, first
    /// creating that save if the game was blank until now.
    private func syncActiveSave() {
        let record = game.record
        guard let index = activeSaveIndex else {
            guard record != Game().record else { return }
            let save = SavedGame(name: SavedGame.automaticName(for: record, createdAt: Date()), record: record)
            savedGames.insert(save, at: 0)
            activeSaveID = save.id
            return
        }
        guard savedGames[index].record != record else { return }
        savedGames[index].record = record
        savedGames[index].updatedAt = Date()
        if !savedGames[index].isNamedByUser {
            savedGames[index].name = SavedGame.automaticName(for: record, createdAt: savedGames[index].createdAt)
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.writeToDisk()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func writeToDisk() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(game) {
            try? data.write(to: fileURL, options: .atomic)
        }
        if let data = try? encoder.encode(SavesFile(saves: savedGames, activeSaveID: activeSaveID)) {
            try? data.write(to: savesURL, options: .atomic)
        }
    }

    func flush() {
        saveWorkItem?.cancel()
        writeToDisk()
    }

    private static func load(from url: URL) -> Game? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Game.self, from: data)
    }

    private static func loadSaves(from url: URL) -> SavesFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavesFile.self, from: data)
    }
}
