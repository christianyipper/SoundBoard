import SwiftUI
import UniformTypeIdentifiers

/// Every text input on the Gamesheet, for focus tracking and Return-key navigation.
enum GamesheetField: Hashable {
    enum GoalSlot: CaseIterable {
        case scorer, assist1, assist2
    }

    case time
    case goal(TeamSide, GoalSlot)
    case penaltyNumber(TeamSide, Int)
    case servedBy(TeamSide, Int)

    /// Where Return moves focus: through the scorer/assists, from a penalty's number to its
    /// served-by number, and otherwise out of the field (which turns hotkeys back on).
    var next: GamesheetField? {
        switch self {
        case .time: nil
        case .goal(let side, .scorer): .goal(side, .assist1)
        case .goal(let side, .assist1): .goal(side, .assist2)
        case .goal(_, .assist2): nil
        case .penaltyNumber(let side, let index): .servedBy(side, index)
        case .servedBy: nil
        }
    }
}

/// Live game entry ported from the ScoreCard app, laid out the same way: team dropdowns either
/// side of the score, then each team's column (shots, goal entry, and penalty rows stacked
/// underneath) either side of the period/time and Game Log (named saves). Hotkeys pause while a
/// text field has focus (ShortcutManager ignores key presses while text is being edited); Return on the last
/// field, Escape, or a click on empty space ends editing and turns them back on (and deselects
/// any selected penalty row).
struct GamesheetView: View {
    @EnvironmentObject private var gameStore: GameStore
    @EnvironmentObject private var rosterStore: RosterStore

    @FocusState private var focus: GamesheetField?

    /// Sides showing their roster in place of the shots/goals/penalties column.
    @State private var rosterSides: Set<TeamSide> = []

    private let centerColumnWidth: CGFloat = 240

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    teamHeading(for: .home)
                    ScoreBox()
                        .frame(width: centerColumnWidth)
                    teamHeading(for: .away)
                }

                HStack(alignment: .top, spacing: 12) {
                    teamColumn(for: .home)
                    VStack(spacing: 12) {
                        PeriodPanel(focus: $focus)
                        GameLogPanel()
                    }
                    .frame(width: centerColumnWidth)
                    teamColumn(for: .away)
                }
                .animation(.easeInOut(duration: 0.25), value: gameStore.activePenaltyRow?.side)
                .animation(.easeInOut(duration: 0.25), value: rosterSides)
            }
            // Top matches the 12pt section gap so the space under the music player reads the same.
            .padding([.horizontal, .bottom], 16)
            .padding(.top, 12)
            // Clicking empty space ends editing so hotkeys work again.
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { endEditing() }
            )
        }
        .overlay(alignment: .bottom) {
            if focus != nil {
                HotkeysPausedPill()
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DesignSystem.Motion.quickFade, value: focus != nil)
        .onExitCommand { endEditing() }
        // AppKit can hand the first text field focus on its own when the view appears, which
        // would silently turn hotkeys off.
        .onAppear { DispatchQueue.main.async { endEditing() } }
        .onDisappear { endEditing() }
        // Clicking into a penalty row's number fields selects that row too.
        .onChange(of: focus) { _, field in
            switch field {
            case .penaltyNumber(let side, let index), .servedBy(let side, let index):
                gameStore.activePenaltyRow = PenaltyRowID(side: side, index: index)
            default:
                break
            }
        }
    }

    /// A side's shots and goal entry with its penalties right underneath, or its roster while
    /// that side's roster toggle is on.
    @ViewBuilder
    private func teamColumn(for side: TeamSide) -> some View {
        if rosterSides.contains(side) {
            RosterPanel(side: side)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
        } else {
            VStack(spacing: 12) {
                TeamPanel(side: side, focus: $focus)
                penaltyColumn(for: side)
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity)
        }
    }

    /// The team name centered over its column, with the roster toggle pinned to the page edge.
    /// Equal padding on both sides keeps the name centered and clear of the toggle.
    private func teamHeading(for side: TeamSide) -> some View {
        TeamNameMenu(side: side)
            .padding(.horizontal, 40)
            .overlay(alignment: side == .home ? .leading : .trailing) {
                RosterToggle(side: side, isOn: rosterBinding(for: side))
            }
    }

    private func rosterBinding(for side: TeamSide) -> Binding<Bool> {
        Binding(
            get: { rosterSides.contains(side) },
            set: { isOn in
                if isOn {
                    endEditing()
                    rosterSides.insert(side)
                } else {
                    rosterSides.remove(side)
                }
            }
        )
    }

    /// A side's penalty rows, or — while a row on the other side is selected — the infraction and
    /// penalty-type buttons for that row, slid in over this column as in the ScoreCard app.
    @ViewBuilder
    private func penaltyColumn(for side: TeamSide) -> some View {
        if gameStore.activePenaltyRow?.side == side.opposite {
            PenaltyPicker(activeSide: side.opposite)
                .transition(.move(edge: side == .home ? .leading : .trailing).combined(with: .opacity))
        } else {
            PenaltyPanel(side: side, focus: $focus)
        }
    }

    private func endEditing() {
        focus = nil
        gameStore.activePenaltyRow = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

// MARK: - Shared styling (also used by CallView)

extension TeamSide {
    var opposite: TeamSide { self == .home ? .away : .home }

    var accent: Color {
        switch self {
        case .home: DesignSystem.Colors.homeTeam
        case .away: DesignSystem.Colors.accentSecondary
        }
    }
}

extension View {
    func gamesheetCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity)
            .glassCard()
    }
}

private enum GamesheetLayout {
    /// Content height shared by the shots cards and the period card so the middle row lines up.
    static let shotsRowHeight: CGFloat = 56
}

private struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .frame(maxWidth: .infinity)
    }
}

/// Filled (or outlined, when `fill` is nil) rounded action button used throughout the Gamesheet.
private struct GamesheetButton<Label: View>: View {
    var fill: Color?
    var outline: Color?
    var height: CGFloat = 36
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.small).fill(fill ?? .clear))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.small)
                        .strokeBorder(outline ?? .clear, lineWidth: 2)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// Rounded input box shared by the time, goal and penalty number fields; outlined in `accent`
/// while focused. Clicking it again while focused ends editing, turning hotkeys back on.
private struct GamesheetTextField: View {
    let placeholder: String
    @Binding var text: String
    let field: GamesheetField
    var focus: FocusState<GamesheetField?>.Binding
    let accent: Color
    var font: Font = .system(size: 18, weight: .bold, design: .rounded).monospacedDigit()
    var height: CGFloat = 36

    private var isFocused: Bool { focus.wrappedValue == field }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .multilineTextAlignment(.center)
            .focused(focus, equals: field)
            .onSubmit { focus.wrappedValue = field.next }
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8).fill(DesignSystem.Colors.background))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isFocused ? accent : DesignSystem.Colors.border, lineWidth: isFocused ? 2 : 1)
            )
            // The focused field's editor swallows clicks, so catch the second click above it.
            .overlay {
                if isFocused {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            focus.wrappedValue = nil
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                        .help("Click to stop editing and resume hotkeys")
                }
            }
    }
}

/// Small name line under a typed jersey number, when the side has a roster: the player's name,
/// or a warning when the number isn't on it.
private struct PlayerCaption: View {
    @EnvironmentObject private var gameStore: GameStore
    @EnvironmentObject private var rosterStore: RosterStore

    let number: String
    let side: TeamSide
    var showsSeasonGoals = false

    var body: some View {
        Group {
            if number.isEmpty || !gameStore.hasRoster(side) {
                Text(" ")
            } else if let player = gameStore.rosterPlayer(number: number, side: side, league: rosterStore.league) {
                Text(showsSeasonGoals ? "\(player.surname) (\(gameStore.seasonGoals(for: player, side: side, league: rosterStore.league)))" : player.surname)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            } else {
                Text("Not on roster")
                    .foregroundStyle(DesignSystem.Colors.dangerGlow)
            }
        }
        .font(.system(size: 18, weight: .medium, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

private struct HotkeysPausedPill: View {
    var body: some View {
        Label("Hotkeys paused while typing", systemImage: "keyboard.badge.ellipsis")
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCard(cornerRadius: 999, tint: DesignSystem.Colors.dangerGlow)
    }
}

// MARK: - Top row

/// The team name is the dropdown for picking the side's league team (Division → Team), which
/// fills in the name and turns on player-name lookups. A custom name can be typed instead.
private struct TeamNameMenu: View {
    @EnvironmentObject private var gameStore: GameStore
    @EnvironmentObject private var rosterStore: RosterStore

    let side: TeamSide

    @State private var isCustomNamePresented = false
    @State private var customName = ""

    var body: some View {
        let selectedID = gameStore.game.teamRosters[side]?.id
        Menu {
            ForEach(rosterStore.league?.divisions ?? []) { division in
                Menu(division.name) {
                    ForEach(division.teams) { team in
                        Button {
                            gameStore.selectRosterTeam(team, for: side)
                        } label: {
                            if team.id == selectedID {
                                Label(team.name, systemImage: "checkmark")
                            } else {
                                Text(team.name)
                            }
                        }
                    }
                }
            }

            Section {
                Button("Custom Name…") {
                    customName = gameStore.teamName(for: side)
                    isCustomNamePresented = true
                }

                if selectedID != nil {
                    Button("No Roster", role: .destructive) {
                        gameStore.selectRosterTeam(nil, for: side)
                    }
                }
            }

            Section(rosterStore.league.map { "Rosters updated \($0.updatedAt.formatted(date: .abbreviated, time: .shortened))" } ?? "No rosters downloaded") {
                Button(rosterStore.isRefreshing ? "Refreshing Rosters…" : "Refresh Rosters") {
                    Task { await rosterStore.refresh() }
                }
                .disabled(rosterStore.isRefreshing)
            }
        } label: {
            HStack(spacing: 8) {
                Text(gameStore.teamName(for: side))
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(side.accent)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .pointerCursor()
        .alert("\(side.defaultName) Team Name", isPresented: $isCustomNamePresented) {
            TextField(side.defaultName, text: $customName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { gameStore.setTeamName(customName, for: side) }
        } message: {
            Text("Keeps the current roster, if one is picked.")
        }
    }
}

/// Person button at the outer edge of a team heading that swaps the side's column for its roster.
private struct RosterToggle: View {
    let side: TeamSide
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: isOn ? "person.fill" : "person")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isOn ? DesignSystem.Colors.textPrimary : side.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(isOn ? side.accent : .clear))
                .overlay(Circle().strokeBorder(side.accent, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(isOn ? "Hide \(side.defaultName.lowercased()) roster" : "Show \(side.defaultName.lowercased()) roster")
    }
}

private struct ScoreBox: View {
    @EnvironmentObject private var gameStore: GameStore

    var body: some View {
        HStack(spacing: 12) {
            score(for: .home)
            Text("Score")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            score(for: .away)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    private func score(for side: TeamSide) -> some View {
        Text("\(gameStore.goalCount(for: side))")
            .font(DesignSystem.Typography.title.monospacedDigit())
            .foregroundStyle(side.accent)
            .frame(minWidth: 40)
    }
}

// MARK: - Middle row

/// The side's picked team: number, name and season goals and assists (official totals plus those
/// recorded here since the last stats update) and penalty minutes, ordered by jersey number.
private struct RosterPanel: View {
    @EnvironmentObject private var gameStore: GameStore
    @EnvironmentObject private var rosterStore: RosterStore

    let side: TeamSide

    private let statWidth: CGFloat = 40

    var body: some View {
        VStack(spacing: 8) {
            if let team = gameStore.rosterTeam(for: side, league: rosterStore.league) {
                let pending = gameStore.pendingStats(for: team)
                header
                Divider()
                ForEach(sorted(team.players)) { player in
                    row(player, pending: pending[RosterPlayer.normalized(player.number)] ?? .init())
                }
                if team.players.isEmpty {
                    emptyText("No players listed for \(team.name)")
                }
            } else {
                emptyText("Pick a league team from the \(side.defaultName.lowercased()) team name to see its roster")
            }
        }
        .gamesheetCard()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("#").frame(width: statWidth)
            Text("Player").frame(maxWidth: .infinity, alignment: .leading)
            Text("G").frame(width: statWidth)
            Text("A").frame(width: statWidth)
            Text("PIM").frame(width: statWidth)
        }
        .font(DesignSystem.Typography.caption)
        .foregroundStyle(DesignSystem.Colors.textSecondary)
    }

    private func row(_ player: RosterPlayer, pending: GameStore.PendingStats) -> some View {
        HStack(spacing: 8) {
            Text(player.number.isEmpty ? "–" : player.number)
                .font(DesignSystem.Typography.headline.monospacedDigit())
                .foregroundStyle(side.accent)
                .frame(width: statWidth)
            Text(player.name)
                .font(DesignSystem.Typography.callout)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                Text("\(player.goals + pending.goals)")
                Text("\(player.assists + pending.assists)")
                Text("\(player.pim)")
            }
            .font(DesignSystem.Typography.callout.monospacedDigit())
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .frame(width: statWidth)
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 12)
    }

    /// Numbered players in jersey order, then anyone without a number by name.
    private func sorted(_ players: [RosterPlayer]) -> [RosterPlayer] {
        players.sorted { a, b in
            switch (Int(a.number), Int(b.number)) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }
}

/// A team's shots card and goal-entry card.
private struct TeamPanel: View {
    @EnvironmentObject private var gameStore: GameStore
    @EnvironmentObject private var rosterStore: RosterStore

    let side: TeamSide
    var focus: FocusState<GamesheetField?>.Binding

    var body: some View {
        VStack(spacing: 12) {
            shotsCard
            goalCard
        }
        .frame(maxWidth: .infinity)
    }

    private var shotsCard: some View {
        HStack(spacing: 10) {
            GamesheetButton(fill: DesignSystem.Colors.textSecondary.opacity(0.35), height: 44) {
                gameStore.addShot(for: side, delta: -1)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            .help("Remove a shot from this period")

            VStack(spacing: 0) {
                Text("\(gameStore.shotCount(for: side, period: gameStore.currentPeriod))")
                    .font(DesignSystem.Typography.title.monospacedDigit())
                Text("Shots · Total \(gameStore.shotTotal(for: side))")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)

            GamesheetButton(fill: side.accent, height: 44) {
                gameStore.addShot(for: side, delta: 1)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.onAccent)
            }
            .help("Add a shot to this period")
        }
        .frame(height: GamesheetLayout.shotsRowHeight)
        .gamesheetCard()
    }

    private var goalCard: some View {
        let draft = gameStore.goalDraft(for: side)
        let canSubmit = gameStore.canSubmitGoal(for: side)
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(GoalStrength.allCases, id: \.self) { strength in
                    let isSelected = gameStore.goalStrengths[side] == strength
                    GamesheetButton(
                        fill: isSelected ? DesignSystem.Colors.successGlow : nil,
                        outline: DesignSystem.Colors.successGlow
                    ) {
                        gameStore.selectGoalStrength(strength, for: side)
                    } label: {
                        Text(strength.label)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(isSelected ? DesignSystem.Colors.onAccent : DesignSystem.Colors.successGlow)
                    }
                }
            }

            HStack(alignment: .top, spacing: 8) {
                goalField("Scorer", slot: .scorer, value: draft.scorer, showsSeasonGoals: true) { $0.scorer = $1 }
                goalField("Assist", slot: .assist1, value: draft.assist1) { $0.assist1 = $1 }
                goalField("Assist", slot: .assist2, value: draft.assist2) { $0.assist2 = $1 }
            }

            GamesheetButton(fill: canSubmit ? DesignSystem.Colors.successGlow : DesignSystem.Colors.textSecondary.opacity(0.25)) {
                gameStore.submitGoal(for: side, league: rosterStore.league)
                focus.wrappedValue = nil
            } label: {
                Text("Add Goal")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(canSubmit ? DesignSystem.Colors.onAccent : DesignSystem.Colors.textSecondary)
            }
            .disabled(!canSubmit)
            .help(canSubmit ? "Record this goal at the current period and time" : "Pick a goal type and enter a scorer")
        }
        .gamesheetCard()
    }

    private func goalField(
        _ placeholder: String,
        slot: GamesheetField.GoalSlot,
        value: String,
        showsSeasonGoals: Bool = false,
        set: @escaping (inout GoalDraft, String) -> Void
    ) -> some View {
        VStack(spacing: 2) {
            GamesheetTextField(
                placeholder: placeholder,
                text: Binding(
                    get: { value },
                    set: { newValue in gameStore.updateGoalDraft(for: side) { set(&$0, JerseyNumber.sanitized(newValue)) } }
                ),
                field: .goal(side, slot),
                focus: focus,
                accent: side.accent
            )
            PlayerCaption(number: value, side: side, showsSeasonGoals: showsSeasonGoals)
        }
    }
}

/// Center column: period picker and the clock time stamped onto goals and penalties.
private struct PeriodPanel: View {
    @EnvironmentObject private var gameStore: GameStore

    var focus: FocusState<GamesheetField?>.Binding

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                SectionLabel(title: "Period")
                SegmentedTabs(selection: Binding(
                    get: { gameStore.currentPeriod },
                    set: { gameStore.currentPeriod = $0 }
                ), options: GamePeriod.allCases) { period in
                    Text(period.label)
                }
            }
            .frame(height: GamesheetLayout.shotsRowHeight)
            .gamesheetCard()

            VStack(spacing: 8) {
                SectionLabel(title: "Time")
                GamesheetTextField(
                    placeholder: "00:00",
                    text: Binding(
                        get: { gameStore.periodTimeText },
                        set: { gameStore.setPeriodTimeText($0) }
                    ),
                    field: .time,
                    focus: focus,
                    accent: DesignSystem.Colors.accentPrimary,
                    font: DesignSystem.Typography.largeTitle.monospacedDigit(),
                    height: 64
                )
                .help("Type the clock time, e.g. 1245 for 12:45. It's stamped onto goals and penalties.")
            }
            .gamesheetCard()
        }
    }
}

// MARK: - Bottom row

private struct PenaltyPanel: View {
    @EnvironmentObject private var gameStore: GameStore

    let side: TeamSide
    var focus: FocusState<GamesheetField?>.Binding

    var body: some View {
        let canSubmit = gameStore.canSubmitPenalties(for: side)
        VStack(spacing: 8) {
            HStack {
                Text("Penalties")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(side.accent)
                Spacer()
            }

            ForEach(0..<PenaltyDraftRow.rowsPerSide, id: \.self) { index in
                row(index)
            }

            GamesheetButton(fill: canSubmit ? DesignSystem.Colors.successGlow : DesignSystem.Colors.textSecondary.opacity(0.25)) {
                gameStore.submitPenalties(for: side)
                focus.wrappedValue = nil
            } label: {
                Text("Submit Penalties")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(canSubmit ? DesignSystem.Colors.onAccent : DesignSystem.Colors.textSecondary)
            }
            .disabled(!canSubmit)
            .help(canSubmit ? "Record every complete row at the current period and time" : "Fill in an infraction, type and player number")
        }
        .gamesheetCard()
    }

    /// Click the row's infraction/type area to select it and start typing the player number
    /// (click again to deselect); the other side's column then shows the buttons for filling it in.
    private func row(_ index: Int) -> some View {
        let id = PenaltyRowID(side: side, index: index)
        let row = gameStore.penaltyRows(for: side)[index]
        let isActive = gameStore.activePenaltyRow == id
        return HStack(alignment: .top, spacing: 6) {
            HStack(spacing: 6) {
                rowValue(row.infraction?.label, placeholder: "Infraction")
                rowValue(row.types.isEmpty ? nil : row.types.ordered.map(\.label).joined(separator: " + "), placeholder: "Type")
            }
            .frame(height: 36)
            .contentShape(Rectangle())
            .onTapGesture {
                gameStore.selectPenaltyRow(id)
                // Jump straight into the player number (Return then moves on to served-by);
                // deselecting the row ends editing.
                focus.wrappedValue = gameStore.activePenaltyRow == id ? .penaltyNumber(side, index) : nil
            }
            .pointerCursor()
            .help("Click to pick the infraction and penalty type")

            VStack(spacing: 2) {
                GamesheetTextField(
                    placeholder: "#",
                    text: Binding(
                        get: { row.playerNumber },
                        set: { value in gameStore.updatePenaltyRow(side: side, index: index) { $0.playerNumber = JerseyNumber.sanitized(value) } }
                    ),
                    field: .penaltyNumber(side, index),
                    focus: focus,
                    accent: side.accent
                )
                if !row.playerNumber.isEmpty && gameStore.hasRoster(side) {
                    PlayerCaption(number: row.playerNumber, side: side)
                }
            }
            .frame(width: 64)
            .help("Penalized player's number")

            GamesheetTextField(
                placeholder: "Srv",
                text: Binding(
                    get: { row.servedBy },
                    set: { value in gameStore.updatePenaltyRow(side: side, index: index) { $0.servedBy = JerseyNumber.sanitized(value) } }
                ),
                field: .servedBy(side, index),
                focus: focus,
                accent: side.accent
            )
            .frame(width: 56)
            .help("Number of the player serving the penalty (optional)")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.small).fill(DesignSystem.Colors.background.opacity(0.6)))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.small)
                .strokeBorder(side.accent, lineWidth: isActive ? 2 : 0)
        )
    }

    private func rowValue(_ value: String?, placeholder: String) -> some View {
        Text(value ?? placeholder)
            .font(.system(size: 18, weight: value == nil ? .regular : .bold, design: .rounded))
            .foregroundStyle(value == nil ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textPrimary)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

/// ScoreCard's penalty picker: a grid of infraction buttons above two rows of penalty-type
/// buttons (Minor / Double Minor / Major, then Match / Misc / GM — one from each row can
/// combine). Applies to the selected penalty row, highlighted in that side's color; clicking the
/// row again, Escape or a click on empty space closes it.
private struct PenaltyPicker: View {
    @EnvironmentObject private var gameStore: GameStore

    let activeSide: TeamSide

    var body: some View {
        let draft = gameStore.activePenaltyDraft
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
                ForEach(Infraction.allCases) { infraction in
                    pickerButton(infraction.label, isSelected: draft?.infraction == infraction) {
                        gameStore.setInfraction(infraction)
                    }
                }
            }

            Rectangle()
                .fill(DesignSystem.Colors.border)
                .frame(height: 1)

            VStack(spacing: 6) {
                ForEach(PenaltyTypeRow.allCases, id: \.self) { group in
                    HStack(spacing: 6) {
                        ForEach(group.types) { type in
                            pickerButton(type.label, isSelected: draft?.types.contains(type) == true) {
                                gameStore.togglePenaltyType(type)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassCard(borderColor: activeSide.accent.opacity(0.6), borderWidth: 2)
    }

    private func pickerButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        GamesheetButton(fill: isSelected ? activeSide.accent : DesignSystem.Colors.textSecondary.opacity(0.25), height: 34, action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(isSelected ? DesignSystem.Colors.onAccent : DesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 4)
        }
    }
}

/// Center column, under the clock: the Game Log of saved games. Games save themselves (see
/// GameStore); the one on screen is the active session, highlighted in purple. Click a save to
/// open it, or right-click to rename or delete it.
private struct GameLogPanel: View {
    @EnvironmentObject private var gameStore: GameStore

    @State private var pendingDelete: SavedGame?
    @State private var renaming: SavedGame?
    @State private var renameText = ""

    private let maxListHeight: CGFloat = 240

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Game Log")
                    .font(DesignSystem.Typography.headline)
                Spacer()
                Button("New Game") { gameStore.newGame() }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.dangerGlow)
                .pointerCursor()
                .help("Start a blank game. The current game stays in the Game Log.")
            }

            if gameStore.savedGames.isEmpty {
                Text("Games save here automatically once you start recording.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(gameStore.savedGames) { save in
                            row(save)
                        }
                    }
                }
                .frame(maxHeight: maxListHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .gamesheetCard()
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "save")?",
            isPresented: isPresented($pendingDelete),
            presenting: pendingDelete
        ) { save in
            Button("Delete", role: .destructive) { gameStore.deleteSave(save.id) }
        } message: { save in
            Text(save.id == gameStore.activeSaveID
                 ? "This is the game on screen, so the gamesheet will be cleared too. This can't be undone."
                 : "This can't be undone.")
        }
        .alert("Rename Save", isPresented: isPresented($renaming), presenting: renaming) { save in
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { gameStore.renameSave(save.id, to: renameText) }
        }
    }

    private func row(_ save: SavedGame) -> some View {
        let isActive = save.id == gameStore.activeSaveID
        return VStack(alignment: .leading, spacing: 1) {
            Text(save.name)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
            Text("\(save.goalCount(for: .home))–\(save.goalCount(for: .away)) · \(save.updatedAt.formatted(date: .omitted, time: .shortened))")
                .font(DesignSystem.Typography.captionBold.monospacedDigit())
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? DesignSystem.Colors.accentPrimary.opacity(0.35) : DesignSystem.Colors.background.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(DesignSystem.Colors.accentPrimary, lineWidth: isActive ? 2 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isActive else { return }
            gameStore.loadSave(save.id)
        }
        .pointerCursor()
        .help(isActive ? "The active session" : "Open this game")
        .contextMenu {
            Button("Rename…") {
                renameText = save.name
                renaming = save
            }
            Button("Delete…", role: .destructive) { pendingDelete = save }
        }
    }

    private func isPresented(_ item: Binding<SavedGame?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}
