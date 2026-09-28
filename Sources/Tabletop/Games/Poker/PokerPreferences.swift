//
//  PokerPreferences.swift
//  What the player last chose — the New Game card's defaults, the pace, the
//  hand-strength pill — and the statistics sheet.
//

import AppKit

struct PokerPreferences: Codable, Equatable {
    var mode: PokerMode = .tournament
    var opponents = 5
    var difficulty: PokerDifficulty = .standard
    var speed: PokerSpeed = .normal
    /// The pill by the player's cards naming their hand.
    var showsHandStrength = true

    static var fileName: String { Storage.fileName("preferences.json", for: .poker) }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.pokerDecode(.mode, .tournament)
        opponents = PokerTableConfig.clampedOpponents(c.pokerDecode(.opponents, 5), includesHuman: true)
        difficulty = c.pokerDecode(.difficulty, .standard)
        speed = c.pokerDecode(.speed, .normal)
        showsHandStrength = c.pokerDecode(.showsHandStrength, true)
    }

    static func load() -> PokerPreferences {
        Storage.load(PokerPreferences.self, from: fileName) ?? PokerPreferences()
    }

    func save() {
        Storage.save(self, to: Self.fileName)
    }

    var config: PokerTableConfig {
        PokerTableConfig(mode: mode, opponents: opponents, difficulty: difficulty, speed: speed)
    }
}

/// The record, plainly: a sheet of rows, and a way to start it again.
@MainActor
enum PokerStatisticsWindow {

    static func show(_ stats: PokerStats, onReset: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Poker Statistics", comment: "poker statistics title")
        alert.accessoryView = makeTable(stats)
        alert.addButton(withTitle: NSLocalizedString("Done", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Reset…", comment: ""))
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = NSLocalizedString("Reset poker statistics?", comment: "")
        confirm.informativeText = NSLocalizedString("This cannot be undone.", comment: "")
        confirm.addButton(withTitle: NSLocalizedString("Reset", comment: ""))
        confirm.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        if confirm.runModal() == .alertFirstButtonReturn { onReset() }
    }

    /// The rows, as (title, value) — for the sheet and for the tests.
    static func rows(_ s: PokerStats) -> [(String, String)] {
        let rate = s.handsPlayed > 0 ? Double(s.handsWon) / Double(s.handsPlayed) : 0
        let percent = NumberFormatter.localizedString(from: NSNumber(value: rate), number: .percent)
        return [
            (NSLocalizedString("Hands played", comment: "poker statistic"), Chips.format(s.handsPlayed)),
            (NSLocalizedString("Hands won", comment: "poker statistic"), Chips.format(s.handsWon)),
            (NSLocalizedString("Hands won, share", comment: "poker statistic: hands won over hands played"),
             s.handsPlayed > 0 ? percent : "—"),
            (NSLocalizedString("Biggest pot won", comment: "poker statistic"), s.biggestPot > 0 ? Chips.format(s.biggestPot) : "—"),
            (NSLocalizedString("Tournaments played", comment: "poker statistic"), Chips.format(s.tournamentsPlayed)),
            (NSLocalizedString("Tournaments won", comment: "poker statistic"), Chips.format(s.tournamentsWon)),
            (NSLocalizedString("Best finish", comment: "poker statistic"), s.bestFinish.map(PokerTableView.ordinal) ?? "—"),
            (NSLocalizedString("Cash games, net", comment: "poker statistic: chips won or lost at cash tables"),
             Chips.formatChange(s.cashNet)),
        ]
    }

    private static func makeTable(_ stats: PokerStats) -> NSView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 28
        grid.rowSpacing = 6
        for (title, value) in rows(stats) {
            let name = NSTextField(labelWithString: title)
            name.font = .systemFont(ofSize: 12)
            name.textColor = .secondaryLabelColor
            let number = NSTextField(labelWithString: value)
            number.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            grid.addRow(with: [name, number])
        }
        grid.column(at: 1).xPlacement = .trailing
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 190))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return container
    }
}
