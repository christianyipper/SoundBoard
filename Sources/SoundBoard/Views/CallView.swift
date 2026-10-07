import SwiftUI

/// Which way the Call tab lists goals and penalties.
enum CallViewMode: String, CaseIterable, Identifiable {
    /// Compact gamesheet lines, with shots per period underneath.
    case sheet
    /// Multi-line scripts for reading each goal and penalty out.
    case call

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sheet: "Sheet"
        case .call: "Call"
        }
    }
}

/// Read-only game report for calling goals, laid out like the ScoreCard app's report grid: each
/// team's goals and penalties listed period by period either side of the period label, with
/// totals underneath. The toggle between the team names switches the entries between Sheet lines
/// (plus a shots grid) and Call scripts. Player names come from the side's roster when one is
/// picked. While this view is up, the hotkey bar shows the "Goal Call" preset (see
/// `MainMode.hotkeyPresetName`).
struct CallView: View {
    @EnvironmentObject private var gameStore: GameStore
    @EnvironmentObject private var rosterStore: RosterStore
    @AppStorage("callViewMode") private var mode: CallViewMode = .sheet
    /// Lines clicked into their team's color; the rest stay grey.
    @State private var highlighted: Set<String> = []

    private let periodColumnWidth: CGFloat = 110
    private let bodyFont = Font.system(size: 18, design: .rounded)

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header

                reportCard(
                    title: "Goals",
                    totalLabel: "Total Goals",
                    events: { side, period in goals(for: side, period: period).map {
                        ReportLine(id: $0.id.uuidString, text: goalText($0))
                    } },
                    total: { gameStore.goalCount(for: $0) }
                )

                reportCard(
                    title: "Penalties",
                    totalLabel: "Total Penalties",
                    events: { side, period in penalties(for: side, period: period).map {
                        ReportLine(id: $0.id.uuidString, text: penaltyText($0))
                    } },
                    total: { side in gameStore.game.penalties.filter { $0.team == side }.count }
                )

                if mode == .sheet {
                    reportCard(
                        title: "Shots",
                        totalLabel: "Total Shots",
                        events: { side, period in [ReportLine(
                            id: "shots-\(side.rawValue)-\(period.rawValue)",
                            text: "\(gameStore.shotCount(for: side, period: period))"
                        )] },
                        total: { gameStore.shotTotal(for: $0) }
                    )
                }
            }
            .padding(16)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            teamName(.home)
            SegmentedTabs(selection: $mode, options: CallViewMode.allCases) { mode in
                Text(mode.label)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: 240)
            .glassCard()
            teamName(.away)
        }
    }

    private func teamName(_ side: TeamSide) -> some View {
        Text(gameStore.teamName(for: side))
            .font(DesignSystem.Typography.title)
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Report grid

    private func reportCard(
        title: String,
        totalLabel: String,
        events: @escaping (TeamSide, GamePeriod) -> [ReportLine],
        total: (TeamSide) -> Int
    ) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 6)

            ForEach(GamePeriod.allCases) { period in
                HStack(alignment: .top, spacing: 12) {
                    eventColumn(events(.home, period), side: .home)
                    Text(period.fullLabel)
                        .font(bodyFont)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: periodColumnWidth)
                    eventColumn(events(.away, period), side: .away)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Rectangle()
                    .fill(DesignSystem.Colors.border)
                    .frame(height: 1)
            }

            HStack(spacing: 12) {
                totalValue(total(.home), side: .home)
                Text(totalLabel)
                    .font(bodyFont.bold())
                    .frame(width: periodColumnWidth)
                totalValue(total(.away), side: .away)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(DesignSystem.Colors.surfaceTint.opacity(0.4))
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    /// Home events hug the left edge and away events the right, as in ScoreCard's report. Lines
    /// are grey until clicked, which toggles them to the team's color.
    private func eventColumn(_ lines: [ReportLine], side: TeamSide) -> some View {
        let alignment: HorizontalAlignment = side == .home ? .leading : .trailing
        return VStack(alignment: alignment, spacing: mode == .call ? 12 : 4) {
            if lines.isEmpty {
                Text("–")
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            } else {
                ForEach(lines) { line in
                    Text(line.text)
                        .fontWeight(.bold)
                        .foregroundStyle(highlighted.contains(line.id) ? side.accent : DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(side == .home ? .leading : .trailing)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if highlighted.remove(line.id) == nil { highlighted.insert(line.id) }
                        }
                }
            }
        }
        .font(bodyFont)
        .frame(maxWidth: .infinity, alignment: side == .home ? .leading : .trailing)
    }

    private func totalValue(_ value: Int, side: TeamSide) -> some View {
        Text("\(value)")
            .font(bodyFont.bold().monospacedDigit())
            .foregroundStyle(side.accent)
            .frame(maxWidth: .infinity, alignment: side == .home ? .leading : .trailing)
    }

    // MARK: - Lines

    /// Entries in the order they were recorded within the period.
    private func goals(for side: TeamSide, period: GamePeriod) -> [GoalEntry] {
        gameStore.game.goals
            .filter { $0.team == side && $0.period == period }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    private func penalties(for side: TeamSide, period: GamePeriod) -> [PenaltyEntry] {
        gameStore.game.penalties
            .filter { $0.team == side && $0.period == period }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    private func goalText(_ goal: GoalEntry) -> String {
        switch mode {
        case .sheet:
            CallText.sheetGoal(goal)
        case .call:
            CallText.callGoal(
                goal,
                teamName: gameStore.teamName(for: goal.team),
                seasonGoal: gameStore.seasonGoalNumber(for: goal, league: rosterStore.league),
                name: { playerName($0, side: goal.team) }
            )
        }
    }

    private func penaltyText(_ penalty: PenaltyEntry) -> String {
        switch mode {
        case .sheet:
            CallText.sheetPenalty(penalty)
        case .call:
            CallText.callPenalty(
                penalty,
                teamName: gameStore.teamName(for: penalty.team),
                name: { playerName($0, side: penalty.team) }
            )
        }
    }

    private func playerName(_ number: String, side: TeamSide) -> String? {
        gameStore.rosterPlayer(number: number, side: side, league: rosterStore.league)?.name
    }
}

/// One goal, penalty, or shot count in the report grid. The id stays the same across the Sheet and
/// Call views, so a highlighted entry stays highlighted when switching.
private struct ReportLine: Identifiable {
    let id: String
    let text: String
}
