//
//  StatusBar.swift
//  The thin readout under the table: score, time, moves, and the two buttons
//  worth having permanently to hand.
//

import AppKit

final class StatusBar: NSView {

    private let scoreLabel = StatusBar.readout()
    private let timeLabel = StatusBar.readout()
    private let movesLabel = StatusBar.readout()
    private let dealLabel = StatusBar.readout()

    private let undoButton = NSButton()
    private let hintButton = NSButton()
    private let finishButton = NSButton()

    static let height: CGFloat = 34

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let stack = NSStackView(views: [dealLabel, scoreLabel, timeLabel, movesLabel])
        stack.orientation = .horizontal
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        configure(undoButton, title: NSLocalizedString("Undo", comment: ""),
                  symbol: "arrow.uturn.backward", action: #selector(GameWindowController.undoMove(_:)))
        configure(hintButton, title: NSLocalizedString("Hint", comment: ""),
                  symbol: "lightbulb", action: #selector(GameWindowController.hint(_:)))
        configure(finishButton, title: NSLocalizedString("Auto-Finish", comment: ""),
                  symbol: "wand.and.sparkles", action: #selector(GameWindowController.autoFinish(_:)))
        finishButton.isHidden = true

        let buttons = NSStackView(views: [finishButton, hintButton, undoButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func readout() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func configure(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.target = nil          // walks the responder chain to the controller
        button.action = action
        button.font = .systemFont(ofSize: 11.5)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    func update(game: Game, scoringMode: ScoringMode) {
        dealLabel.stringValue = String(
            format: NSLocalizedString("Deal %d", comment: "deal number"), game.dealNumber)

        switch scoringMode {
        case .none:
            scoreLabel.stringValue = ""
        case .vegas:
            let score = game.displayScore
            scoreLabel.stringValue = String(
                format: NSLocalizedString("Score  %@$%d", comment: "vegas score"),
                score < 0 ? "−" : "", abs(score))
        case .standard:
            scoreLabel.stringValue = String(
                format: NSLocalizedString("Score  %d", comment: "score"), game.displayScore)
        }

        let seconds = Int(game.elapsed)
        timeLabel.stringValue = String(
            format: NSLocalizedString("Time  %d:%02d", comment: "elapsed time"),
            seconds / 60, seconds % 60)
        movesLabel.stringValue = String(
            format: NSLocalizedString("Moves  %d", comment: "move count"), game.actionCount)

        undoButton.isEnabled = game.canUndo
        hintButton.isEnabled = !game.isWon
        finishButton.isHidden = !game.canAutoFinish
    }
}
