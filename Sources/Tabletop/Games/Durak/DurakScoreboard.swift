//
//  DurakScoreboard.swift
//  Tonight's tally — who has been the durak how often — as a small glass
//  panel under the end-of-game banner, and the player's lifetime record as
//  a plain sheet (Durak ▸ Statistics…).
//
//  The tally is the thing people actually talk about at a durak table
//  ("that's three times you've been the fool tonight"), so it is shown at
//  the end of every game rather than hidden in a menu; the menu has it too.
//

import AppKit

/// "This session": one row per player with the number of times they were
/// the durak, and a line with the games and draws.
final class DurakScoreboardView: NSView {

    private let panel = GlassPanel(cornerRadius: Radius.large)
    private let header = Typography.label("", font: Typography.eyebrow, color: Palette.textTertiary)
    private let column = Typography.label("", font: Typography.eyebrow, color: Palette.textTertiary)
    private var rows: [(avatar: NSImageView, name: NSTextField, count: NSTextField)] = []
    private let footer = Typography.label("", font: Typography.caption, color: Palette.textTertiary)
    private let names: [String]

    static let width: CGFloat = 272
    private static let rowHeight: CGFloat = 28
    private static let padding: CGFloat = 18

    init(names: [String], scoreboard: DurakScoreboard, loser: Int?) {
        self.names = names
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(panel)
        let content = panel.contentView
        header.attributedStringValue = NSAttributedString(
            string: NSLocalizedString("This session", comment: "durak scoreboard heading").uppercased(),
            attributes: Typography.attributes(Typography.eyebrow, Palette.textTertiary, kern: Typography.eyebrowKern))
        column.attributedStringValue = NSAttributedString(
            string: NSLocalizedString("Durak", comment: "durak scoreboard column: times the player was the durak").uppercased(),
            attributes: Typography.attributes(Typography.eyebrow, Palette.textTertiary, kern: Typography.eyebrowKern,
                                              alignment: .right))
        column.alignment = .right
        content.addSubview(header)
        content.addSubview(column)

        for (seat, name) in names.enumerated() {
            let avatar = NSImageView()
            avatar.imageScaling = .scaleProportionallyUpOrDown
            if let image = AvatarRenderer.image(name: name, avatar: seat == DurakMatch.human ? .symbol("person.fill") : .initials,
                                                diameter: 20, scale: 2) {
                avatar.image = NSImage(cgImage: image, size: NSSize(width: 20, height: 20))
            }
            content.addSubview(avatar)
            let isLoser = seat == loser
            let label = Typography.label(name, font: isLoser ? Typography.headline : Typography.body,
                                         color: isLoser ? Palette.textPrimary : Palette.textSecondary)
            let times = scoreboard.durakCounts.indices.contains(seat) ? scoreboard.durakCounts[seat] : 0
            let count = Typography.label(times == 0 ? "–" : String.localizedStringWithFormat("%d", times),
                                         font: Typography.number(15, weight: isLoser ? .bold : .semibold),
                                         color: isLoser ? Palette.accentSoft : (times == 0 ? Palette.textTertiary : Palette.textPrimary))
            count.alignment = .right
            content.addSubview(label)
            content.addSubview(count)
            rows.append((avatar, label, count))
        }
        let games = Plural.format(scoreboard.games, one: NSLocalizedString("%d game", comment: "durak scoreboard"),
                                  other: NSLocalizedString("%d games", comment: "durak scoreboard"))
        if scoreboard.draws > 0 {
            let draws = Plural.format(scoreboard.draws, one: NSLocalizedString("%d draw", comment: "durak scoreboard"),
                                      other: NSLocalizedString("%d draws", comment: "durak scoreboard"))
            footer.stringValue = String(format: NSLocalizedString("%@ · %@", comment: "durak scoreboard: games · draws"), games, draws)
        } else {
            footer.stringValue = games
        }
        content.addSubview(footer)
        frame.size = fittingSize
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(accessibilitySummary(scoreboard))
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // information, not a control

    override var fittingSize: NSSize {
        NSSize(width: Self.width, height: Self.padding * 2 + 18 + 8 + CGFloat(rows.count) * Self.rowHeight + 22)
    }

    override func layout() {
        super.layout()
        panel.frame = bounds
        let p = Self.padding
        let inner = bounds.width - 2 * p
        header.frame = CGRect(x: p, y: p, width: inner * 0.7, height: 16)
        column.frame = CGRect(x: p + inner * 0.5, y: p, width: inner * 0.5, height: 16)
        var y = p + 18 + 8
        for row in rows {
            row.avatar.frame = CGRect(x: p, y: y + (Self.rowHeight - 20) / 2, width: 20, height: 20)
            let nameHeight = row.name.intrinsicContentSize.height
            row.name.frame = CGRect(x: p + 30, y: (y + (Self.rowHeight - nameHeight) / 2).rounded(),
                                    width: inner - 30 - 48, height: nameHeight)
            let countHeight = row.count.intrinsicContentSize.height
            row.count.frame = CGRect(x: p + inner - 48, y: (y + (Self.rowHeight - countHeight) / 2).rounded(),
                                     width: 48, height: countHeight)
            y += Self.rowHeight
        }
        footer.frame = CGRect(x: p, y: y + 6, width: inner, height: 16)
    }

    private func accessibilitySummary(_ board: DurakScoreboard) -> String {
        var parts = [NSLocalizedString("This session", comment: "durak scoreboard heading")]
        for (seat, name) in names.enumerated() {
            let times = board.durakCounts.indices.contains(seat) ? board.durakCounts[seat] : 0
            parts.append(Plural.format(times, one: String(format: NSLocalizedString("%@: durak %%d time", comment: "durak scoreboard, accessibility"), name),
                                       other: String(format: NSLocalizedString("%@: durak %%d times", comment: "durak scoreboard, accessibility"), name)))
        }
        return parts.joined(separator: ", ")
    }
}

/// The player's record, per variant, in a sheet like Solitaire's.
enum DurakStatisticsWindow {

    @MainActor
    static func show(statistics: DurakStatistics, onReset: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Durak Statistics", comment: "durak statistics sheet title")
        alert.accessoryView = makeTable(statistics)
        alert.addButton(withTitle: NSLocalizedString("Done", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Reset…", comment: ""))
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = NSLocalizedString("Reset durak statistics?", comment: "")
        confirm.informativeText = NSLocalizedString("This cannot be undone.", comment: "")
        confirm.addButton(withTitle: NSLocalizedString("Reset", comment: ""))
        confirm.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        if confirm.runModal() == .alertFirstButtonReturn { onReset() }
    }

    @MainActor
    private static func makeTable(_ statistics: DurakStatistics) -> NSView {
        func percent(_ part: Int, _ whole: Int) -> String {
            guard whole > 0 else { return "–" }
            return NumberFormatter.localizedString(from: NSNumber(value: Double(part) / Double(whole)), number: .percent)
        }
        // Counts in the reader's own digits and grouping.
        func count(_ n: Int) -> String { String.localizedStringWithFormat("%d", n) }
        let rows: [(String, (DurakStatistics.Record) -> String)] = [
            (NSLocalizedString("Games played", comment: "durak statistics"), { count($0.played) }),
            (NSLocalizedString("Not the durak", comment: "durak statistics: games the player escaped"), { count($0.escaped) }),
            (NSLocalizedString("Out first", comment: "durak statistics: games the player went out first"), { count($0.firstOut) }),
            (NSLocalizedString("The durak", comment: "durak statistics: games the player lost («Дурак»)"), { count($0.durak) }),
            (NSLocalizedString("Draws", comment: "durak statistics («Ничья»)"), { count($0.draws) }),
            (NSLocalizedString("Escape rate", comment: "durak statistics: share of games not lost"), { percent($0.escaped, $0.played) }),
        ]
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 22
        grid.rowSpacing = 6
        grid.addRow(with: [
            label("", bold: true),
            label(DurakVariant.podkidnoy.localizedName, bold: true),
            label(DurakVariant.perevodnoy.localizedName, bold: true),
        ])
        for (title, value) in rows {
            grid.addRow(with: [label(title), label(value(statistics.podkidnoy), monospaced: true),
                               label(value(statistics.perevodnoy), monospaced: true)])
        }
        grid.column(at: 1).xPlacement = .trailing
        grid.column(at: 2).xPlacement = .trailing
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 180))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return container
    }

    @MainActor
    private static func label(_ text: String, bold: Bool = false, monospaced: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = monospaced ? .monospacedDigitSystemFont(ofSize: 12, weight: bold ? .semibold : .regular)
                                : .systemFont(ofSize: 12, weight: bold ? .semibold : .regular)
        if !bold && !monospaced { field.textColor = .secondaryLabelColor }
        return field
    }
}
