import Foundation

/// Owns the live game shown in the Gamesheet view (ported from the ScoreCard app): team names and
/// rosters, the current period and clock time, shots per period, and the recorded goals and
/// penalties. The recorded game is saved to disk so it survives a relaunch mid-game; the
/// in-progress goal/penalty inputs are not. It also keeps the saved games, which the sidebar lists
/// as playlists (every one shares the same sound library). Saving is automatic: "New Game" (or the
/// first change to a blank game) creates a save, which becomes the active session, and every later
/// change is copied into that save as it happens.
final class GameStore: ObservableObject {
    struct Game: Codable, Equatable {
        var teamNames: [TeamSide: String] = [.home: TeamSide.home.defaultName, .away: TeamSide.away.defaultName]
        var teamRosters: [TeamSide: RosterTeam] = [:]
        var currentPeriod: GamePeriod = .first
        /// Up to four digits typed into the time field, e.g. "1245" for 12:45.
        var periodTimeDigits = ""
        var shots: [TeamSide: [GamePeriod: Int]] = [:]
        var goalkeepers: [TeamSide: GoalkeeperEntry] = [:]
        var officials = Officials()
        var goals: [GoalEntry] = []
        var penalties: [PenaltyEntry] = []
    }

    @Published private(set) var game: Game {
        didSet {
            syncActiveSave()
            scheduleSave()
        }
    }

    /// Every saved game, newest first.
    @Published private(set) var savedGames: [SavedGame] = []
    /// The save the live game belongs to; nil while it's unsaved.
    @Published private(set) var activeSaveID: UUID?

    @Published var goalDrafts: [TeamSide: GoalDraft] = [:]
    @Published var goalStrengths: [TeamSide: GoalStrength] = [:]
    @Published var penaltyDrafts: [TeamSide: [PenaltyDraftRow]] = GameStore.emptyPenaltyDrafts()
    /// The penalty row the infraction/type buttons apply to. While set, the opposite side's
    /// column shows those buttons in place of its penalty rows.
    @Published var activePenaltyRow: PenaltyRowID?
    /// Whether the clock is counting down after a +30s/+60s press.
    @Published private(set) var clockState: ClockState = .stopped

    private let fileURL: URL
    private let savesURL: URL
    private var saveWorkItem: DispatchWorkItem?
    private var clockTimer: Timer?

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

    /// Goals and assists recorded for `team` (pass the league's latest copy) across every saved
    /// game, keyed by normalized jersey number. A goal stays pending until the league's
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
        Self.clockText(fromDigits: game.periodTimeDigits)
    }

    /// Keeps only the first four digits of whatever was typed (so "12:45" and "1245" both work).
    /// Typing a new time stops the countdown.
    func setPeriodTimeText(_ text: String) {
        let digits = Self.clockDigits(from: text)
        guard digits != game.periodTimeDigits else { return }
        stopClock()
        game.periodTimeDigits = digits
    }

    // MARK: - Countdown

    enum ClockState {
        case stopped
        case running
        /// Held while the time field is being edited; resumes when editing ends.
        case paused
    }

    /// The most the four-digit time field holds (99:59).
    static let maxClockSeconds = 99 * 60 + 59

    /// The time field's value in seconds ("1245" → 765).
    var clockSeconds: Int {
        let value = Int(game.periodTimeDigits) ?? 0
        return value / 100 * 60 + value % 100
    }

    /// Adds `seconds` to the time and counts it down to 0:00, once a second.
    func addClockTime(seconds: Int) {
        setClockSeconds(min(clockSeconds + seconds, Self.maxClockSeconds))
        startClockTimer()
    }

    /// Holds a running countdown (while the time field is being edited).
    func pauseClock() {
        guard clockState == .running else { return }
        invalidateClockTimer()
        clockState = .paused
    }

    /// Picks a paused countdown back up.
    func resumeClock() {
        guard clockState == .paused else { return }
        startClockTimer()
    }

    func stopClock() {
        invalidateClockTimer()
        clockState = .stopped
    }

    /// One second off the countdown; stops at 0:00.
    func tickClock() {
        let remaining = max(0, clockSeconds - 1)
        setClockSeconds(remaining)
        if remaining == 0 { stopClock() }
    }

    private func setClockSeconds(_ seconds: Int) {
        let seconds = max(0, seconds)
        game.periodTimeDigits = "\(seconds / 60)" + String(format: "%02d", seconds % 60)
    }

    private func startClockTimer() {
        invalidateClockTimer()
        guard clockSeconds > 0 else {
            clockState = .stopped
            return
        }
        clockState = .running
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tickClock() }
        // Common modes so it keeps ticking while a menu or scroll is tracking.
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func invalidateClockTimer() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    static func clockText(fromDigits digits: String) -> String {
        guard digits.count > 2 else { return digits }
        return "\(digits.dropLast(2)):\(digits.suffix(2))"
    }

    static func clockDigits(from text: String) -> String {
        String(text.filter(\.isASCIIDigit).prefix(4))
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

    // MARK: - Goalkeepers

    func goalkeepers(for side: TeamSide) -> GoalkeeperEntry {
        game.goalkeepers[side] ?? GoalkeeperEntry()
    }

    func updateGoalkeepers(for side: TeamSide, _ change: (inout GoalkeeperEntry) -> Void) {
        var entry = goalkeepers(for: side)
        change(&entry)
        game.goalkeepers[side] = entry == GoalkeeperEntry() ? nil : entry
    }

    /// The sub time field's text, formatted like `periodTimeText`.
    func goalieSubTimeText(for side: TeamSide) -> String {
        Self.clockText(fromDigits: goalkeepers(for: side).subTimeDigits)
    }

    func setGoalieSubTimeText(_ text: String, for side: TeamSide) {
        updateGoalkeepers(for: side) { $0.subTimeDigits = Self.clockDigits(from: text) }
    }

    // MARK: - Officials

    func officialName(_ role: Officials.Role, index: Int) -> String {
        game.officials[role][index]
    }

    func setOfficialName(_ name: String, role: Officials.Role, index: Int) {
        game.officials[role][index] = name
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

    /// Adds `infraction` to the active row, or removes it if it's already there.
    func toggleInfraction(_ infraction: Infraction) {
        guard let row = activePenaltyRow else { return }
        updatePenaltyRow(side: row.side, index: row.index) {
            if let index = $0.infractions.firstIndex(of: infraction) {
                $0.infractions.remove(at: index)
            } else {
                $0.infractions.append(infraction)
            }
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
            game.penalties.append(PenaltyEntry(
                team: side,
                period: game.currentPeriod,
                time: stampedTime,
                infractions: row.infractions,
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

    /// Starts a blank game with its own save, so it's listed right away. The previous save keeps
    /// its contents.
    func newGame() {
        let save = SavedGame(name: SavedGame.automaticName(for: Game().record, createdAt: Date()), record: Game().record)
        savedGames.insert(save, at: 0)
        activeSaveID = save.id
        resetLiveGame(to: Game())
        scheduleSave()
    }

    /// Clears the live game and inputs without saving anything; the next change saves it.
    private func clearToUnsavedGame() {
        activeSaveID = nil
        resetLiveGame(to: Game())
    }

    /// Replaces the live game, clearing any half-typed goal/penalty inputs.
    private func resetLiveGame(to newGame: Game) {
        stopClock()
        game = newGame
        goalDrafts = [:]
        goalStrengths = [:]
        penaltyDrafts = Self.emptyPenaltyDrafts()
        activePenaltyRow = nil
    }

    // MARK: - Saved games

    /// Replaces the live game with a save's contents and makes it the active session. The period
    /// and clock start over, and any half-typed goal/penalty inputs are cleared.
    func loadSave(_ id: UUID) {
        guard let save = savedGames.first(where: { $0.id == id }) else { return }
        activeSaveID = id
        var loaded = Game()
        loaded.record = save.record
        resetLiveGame(to: loaded)
    }

    /// An empty name keeps the old one.
    func renameSave(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = savedGames.firstIndex(where: { $0.id == id }) else { return }
        savedGames[index].name = trimmed
        savedGames[index].isNamedByUser = true
        scheduleSave()
    }

    /// Deleting the active save opens the newest remaining one, or clears the gamesheet when none
    /// are left (otherwise the next change would just save it again).
    func deleteSave(_ id: UUID) {
        savedGames.removeAll { $0.id == id }
        if activeSaveID == id {
            if let next = savedGames.first {
                loadSave(next.id)
            } else {
                clearToUnsavedGame()
            }
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

// Games saved before goalkeepers or officials were tracked have no `goalkeepers`/`officials` key.
extension GameStore.Game {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        teamNames = try container.decode([TeamSide: String].self, forKey: .teamNames)
        teamRosters = try container.decode([TeamSide: RosterTeam].self, forKey: .teamRosters)
        currentPeriod = try container.decode(GamePeriod.self, forKey: .currentPeriod)
        periodTimeDigits = try container.decode(String.self, forKey: .periodTimeDigits)
        shots = try container.decode([TeamSide: [GamePeriod: Int]].self, forKey: .shots)
        goalkeepers = try container.decodeIfPresent([TeamSide: GoalkeeperEntry].self, forKey: .goalkeepers) ?? [:]
        officials = try container.decodeIfPresent(Officials.self, forKey: .officials) ?? Officials()
        goals = try container.decode([GoalEntry].self, forKey: .goals)
        penalties = try container.decode([PenaltyEntry].self, forKey: .penalties)
    }
}
