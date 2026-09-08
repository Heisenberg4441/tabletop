//
//  StatisticsWindow.swift
//  A plain, readable record of how the player has been doing.
//

import AppKit

enum StatisticsWindow {

    static func show(statistics: Statistics, onReset: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Statistics", comment: "")
        alert.accessoryView = makeTable(statistics)
        alert.addButton(withTitle: NSLocalizedString("Done", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Reset…", comment: ""))
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = NSLocalizedString("Reset all statistics?", comment: "")
        confirm.informativeText = NSLocalizedString("This cannot be undone.", comment: "")
        confirm.addButton(withTitle: NSLocalizedString("Reset", comment: ""))
        confirm.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        if confirm.runModal() == .alertFirstButtonReturn { onReset() }
    }

    private static func makeTable(_ statistics: Statistics) -> NSView {
        let rows: [(String, (Statistics.Record) -> String)] = [
            (NSLocalizedString("Games played", comment: ""), { "\($0.played)" }),
            (NSLocalizedString("Games won", comment: ""), { "\($0.won)" }),
            (NSLocalizedString("Win rate", comment: ""), { String(format: "%.0f%%", $0.winPercentage) }),
            (NSLocalizedString("Current streak", comment: ""), { "\($0.currentStreak)" }),
            (NSLocalizedString("Longest streak", comment: ""), { "\($0.longestStreak)" }),
            (NSLocalizedString("Fastest win", comment: ""), { record in
                guard let t = record.fastestWin else { return "—" }
                return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
            }),
            (NSLocalizedString("Fewest moves", comment: ""), { $0.fewestMoves.map(String.init) ?? "—" }),
            (NSLocalizedString("Best score", comment: ""), { $0.bestScore.map(String.init) ?? "—" }),
            (NSLocalizedString("Time played", comment: ""), { record in
                let t = Int(record.totalTime)
                return t >= 3600 ? String(format: "%dh %dm", t / 3600, (t % 3600) / 60)
                                 : String(format: "%dm", t / 60)
            }),
        ]

        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 22
        grid.rowSpacing = 6

        let header = grid.addRow(with: [
            label("", bold: true),
            label(NSLocalizedString("Draw One", comment: ""), bold: true),
            label(NSLocalizedString("Draw Three", comment: ""), bold: true),
        ])
        header.height = 20

        for (title, value) in rows {
            grid.addRow(with: [
                label(title),
                label(value(statistics.drawOne), monospaced: true),
                label(value(statistics.drawThree), monospaced: true),
            ])
        }
        grid.column(at: 1).xPlacement = .trailing
        grid.column(at: 2).xPlacement = .trailing

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 250))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return container
    }

    private static func label(_ text: String, bold: Bool = false, monospaced: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        if monospaced {
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: bold ? .semibold : .regular)
        } else {
            field.font = .systemFont(ofSize: 12, weight: bold ? .semibold : .regular)
        }
        if !bold && !monospaced { field.textColor = .secondaryLabelColor }
        return field
    }
}
