//
//  BlackjackStatistics.swift
//  The player's record at the table, and the file the table is kept in.
//
//  Two files, both prefixed with the game's id: `blackjack-state.json` is
//  the table itself — bankroll, rules, the shoe card by card, the round in
//  play, the last bet, the coach — so a player who quits mid-shoe (or
//  mid-hand) sits back down at exactly the same table; `blackjack-stats.json`
//  is the record, which survives a new shoe and a reset bankroll.
//

import AppKit

struct BlackjackStatistics: Codable, Equatable {

    var rounds = 0
    /// Every hand played, a split counting each of its hands.
    var hands = 0
    var wins = 0
    var losses = 0
    var pushes = 0
    var blackjacks = 0
    /// The best single round, net.
    var biggestWin = BlackjackAmount.zero
    var peakBankroll = BlackjackAmount(BlackjackRules.startingBankroll)
    /// Everything won less everything lost.
    var net = BlackjackAmount.zero

    static let fileName = Storage.fileName("stats.json", for: .blackjack)

    init() {}

    /// Counts a settled round.
    mutating func record(_ round: BlackjackRound, bankroll: BlackjackAmount) {
        guard round.phase == .settled else { return }
        rounds += 1
        for hand in round.hands {
            guard let result = hand.result else { continue }
            hands += 1
            if result.isWin { wins += 1 } else if result.isLoss { losses += 1 } else { pushes += 1 }
            if result == .blackjack || result == .evenMoney || (result == .push && hand.isBlackjack) {
                blackjacks += 1
            }
        }
        net += round.net
        biggestWin = max(biggestWin, round.net)
        peakBankroll = max(peakBankroll, bankroll)
    }

    /// A round walked away from counts every unsettled hand as lost.
    mutating func recordForfeit(hands count: Int, staked: BlackjackAmount) {
        guard count > 0 else { return }
        rounds += 1
        hands += count
        losses += count
        net -= staked
    }

    private enum CodingKeys: String, CodingKey {
        case rounds, hands, wins, losses, pushes, blackjacks, biggestWin, peakBankroll, net
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Counts a lifetime could reach and no more, so a damaged file can
        // never make the next `+= 1` overflow.
        let most = 1_000_000_000_000
        func count(_ key: CodingKeys) -> Int {
            max(0, min(most, ((try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil) ?? 0))
        }
        func amount(_ key: CodingKeys, _ fallback: BlackjackAmount, from low: BlackjackAmount) -> BlackjackAmount {
            (((try? c.decodeIfPresent(BlackjackAmount.self, forKey: key)) ?? nil) ?? fallback)
                .clamped(to: low...BlackjackAmount(most))
        }
        rounds = count(.rounds)
        hands = count(.hands)
        wins = count(.wins)
        losses = count(.losses)
        pushes = count(.pushes)
        blackjacks = count(.blackjacks)
        biggestWin = amount(.biggestWin, .zero, from: .zero)
        peakBankroll = amount(.peakBankroll, BlackjackAmount(BlackjackRules.startingBankroll), from: .zero)
        net = amount(.net, .zero, from: -BlackjackAmount(most))
    }

    static func load() -> BlackjackStatistics {
        Storage.load(BlackjackStatistics.self, from: fileName) ?? BlackjackStatistics()
    }

    func save() {
        Storage.save(self, to: Self.fileName)
    }

    // MARK: Showing

    /// The record, as a sheet on `window` (or a modal alert without one),
    /// with a way to start it again.
    @MainActor
    static func present(_ statistics: BlackjackStatistics, in window: NSWindow?, onReset: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Blackjack Statistics", comment: "statistics sheet title")
        alert.accessoryView = table(statistics)
        alert.addButton(withTitle: NSLocalizedString("Done", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Reset…", comment: "statistics: start the record again"))
        let confirmReset = {
            let confirm = NSAlert()
            confirm.alertStyle = .warning
            confirm.messageText = NSLocalizedString("Reset your blackjack statistics?", comment: "")
            confirm.informativeText = NSLocalizedString("Your bankroll and the shoe are not affected. This cannot be undone.",
                                                        comment: "blackjack statistics reset")
            confirm.addButton(withTitle: NSLocalizedString("Reset", comment: ""))
            confirm.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            if confirm.runModal() == .alertFirstButtonReturn { onReset() }
        }
        if let window {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertSecondButtonReturn else { return }
                MainActor.assumeIsolated { DispatchQueue.main.async { confirmReset() } }
            }
        } else if alert.runModal() == .alertSecondButtonReturn {
            confirmReset()
        }
    }

    private static func table(_ s: BlackjackStatistics) -> NSView {
        func percent(_ n: Int) -> String {
            s.hands == 0 ? "—" : String(format: NSLocalizedString("%.0f%%", comment: "a percentage"),
                                         Double(n) * 100 / Double(s.hands))
        }
        let rows: [(String, String)] = [
            (NSLocalizedString("Rounds played", comment: "blackjack statistics"), Chips.format(s.rounds)),
            (NSLocalizedString("Hands played", comment: "blackjack statistics"), Chips.format(s.hands)),
            (NSLocalizedString("Won", comment: "blackjack statistics"), "\(Chips.format(s.wins))  \(percent(s.wins))"),
            (NSLocalizedString("Lost", comment: "blackjack statistics"), "\(Chips.format(s.losses))  \(percent(s.losses))"),
            (NSLocalizedString("Pushed", comment: "blackjack statistics"), "\(Chips.format(s.pushes))  \(percent(s.pushes))"),
            (NSLocalizedString("Blackjacks", comment: "blackjack statistics"), Chips.format(s.blackjacks)),
            (NSLocalizedString("Biggest win", comment: "blackjack statistics"),
             s.biggestWin > .zero ? s.biggestWin.formattedChange : "—"),
            (NSLocalizedString("Peak bankroll", comment: "blackjack statistics"), s.peakBankroll.formatted),
            (NSLocalizedString("Net", comment: "blackjack statistics: total won less lost"), s.net.formattedChange),
        ]
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 28
        grid.rowSpacing = 6
        for (title, value) in rows {
            let name = NSTextField(labelWithString: title)
            name.font = .systemFont(ofSize: 12)
            name.textColor = .secondaryLabelColor
            let number = NSTextField(labelWithString: value)
            number.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            grid.addRow(with: [name, number])
        }
        grid.column(at: 1).xPlacement = .trailing
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: CGFloat(rows.count) * 22 + 4))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }
}

/// Everything in `blackjack-state.json`.
struct BlackjackSavedTable: Codable {

    var engine: BlackjackEngine
    var coach: BlackjackCoachLevel
    /// Shoes started at this table — part of the next shoe's seed in the
    /// harness, where seeds are not random.
    var shoesStarted: Int

    static let fileName = Storage.fileName("state.json", for: .blackjack)

    init(engine: BlackjackEngine, coach: BlackjackCoachLevel, shoesStarted: Int) {
        self.engine = engine
        self.coach = coach
        self.shoesStarted = shoesStarted
    }

    private enum CodingKeys: String, CodingKey { case engine, coach, shoesStarted }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Without a table there is nothing to restore; the caller starts afresh.
        engine = try c.decode(BlackjackEngine.self, forKey: .engine)
        coach = ((try? c.decodeIfPresent(BlackjackCoachLevel.self, forKey: .coach)) ?? nil) ?? .hints
        shoesStarted = max(1, min(1_000_000_000, ((try? c.decodeIfPresent(Int.self, forKey: .shoesStarted)) ?? nil) ?? 1))
    }

    static func load() -> BlackjackSavedTable? {
        Storage.load(BlackjackSavedTable.self, from: fileName)
    }

    func save() {
        Storage.save(self, to: Self.fileName)
    }
}
