import Foundation

/// The four plain (no-modifier) keys that add/remove a shot for home/away in the current period,
/// stored as physical key codes and editable in Settings. Defaults to A/Z (home +/-) and D/C (away +/-).
struct ShotHotkeys: Codable, Equatable {
    var homeAdd: UInt16
    var homeRemove: UInt16
    var awayAdd: UInt16
    var awayRemove: UInt16

    static let `default` = ShotHotkeys(homeAdd: 0, homeRemove: 6, awayAdd: 2, awayRemove: 8)

    /// One editable shot hotkey: which side, and whether it adds (+1) or removes (-1) a shot.
    struct Action: Identifiable, Hashable {
        let side: TeamSide
        let delta: Int

        var id: String { "\(side.rawValue)\(delta)" }

        var label: String {
            "\(side.defaultName) \(delta > 0 ? "Add Shot" : "Remove Shot")"
        }
    }

    static let actions: [Action] = [
        Action(side: .home, delta: 1),
        Action(side: .home, delta: -1),
        Action(side: .away, delta: 1),
        Action(side: .away, delta: -1),
    ]

    subscript(action: Action) -> UInt16 {
        get {
            switch (action.side, action.delta > 0) {
            case (.home, true): return homeAdd
            case (.home, false): return homeRemove
            case (.away, true): return awayAdd
            case (.away, false): return awayRemove
            }
        }
        set {
            switch (action.side, action.delta > 0) {
            case (.home, true): homeAdd = newValue
            case (.home, false): homeRemove = newValue
            case (.away, true): awayAdd = newValue
            case (.away, false): awayRemove = newValue
            }
        }
    }

    func keyCode(for side: TeamSide, delta: Int) -> UInt16 {
        self[Action(side: side, delta: delta)]
    }

    func action(forKeyCode keyCode: UInt16) -> Action? {
        Self.actions.first { self[$0] == keyCode }
    }

    /// Assigns `keyCode` to `action`. If another shot action already used that key, it takes
    /// `action`'s old key instead, so no two shot actions ever share a key.
    mutating func assign(_ keyCode: UInt16, to action: Action) {
        if let other = self.action(forKeyCode: keyCode), other != action {
            self[other] = self[action]
        }
        self[action] = keyCode
    }
}
