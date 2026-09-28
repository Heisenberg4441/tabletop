//
//  BoardAccessibility.swift
//  Makes the table readable, and playable, without looking at it.
//
//  The board is drawn into layers rather than built out of views, so none of it
//  is visible to VoiceOver for free. Each pile gets a synthetic element that
//  describes what is on it and can be pressed to play it — which is exactly the
//  click-to-move gesture the game is built around, so a VoiceOver player gets
//  the same one-action-per-card game everyone else does.
//

import AppKit

/// One pile, exposed to assistive technology.
final class PileAccessibilityElement: NSAccessibilityElement {

    var pile: PileID = .stock
    weak var board: BoardView?

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        board?.performAccessibilityPress(on: pile) ?? false
    }
}

extension BoardView {

    /// Rebuilt whenever the board changes; VoiceOver reads the labels fresh
    /// each time it asks, so only the frames and the identities need caching.
    func rebuildAccessibilityElements() {
        var elements: [PileAccessibilityElement] = []
        for slot in boardLayout.pileSlots {
            let element = PileAccessibilityElement()
            element.pile = slot.pile
            element.board = self
            element.setAccessibilityParent(self)
            var frame = slot.frame
            if slot.pile.kind == .tableau {
                let column = game.state.tableau[slot.pile.index]
                let (down, up) = boardLayout.fanOffsets(column: column)
                frame.size.height += CGFloat(column.down.count) * down
                    + CGFloat(max(0, column.up.count - 1)) * up
            }
            element.setAccessibilityFrameInParentSpace(frame)
            element.setAccessibilityLabel(label(for: slot.pile))
            element.setAccessibilityValue(value(for: slot.pile))
            elements.append(element)
        }
        pileAccessibilityElements = elements
    }

    private func label(for pile: PileID) -> String {
        switch pile.kind {
        case .stock:
            return NSLocalizedString("Stock", comment: "accessibility: face-down pile")
        case .waste:
            return NSLocalizedString("Waste", comment: "accessibility: turned-over pile")
        case .foundation:
            let suit = Suit(rawValue: UInt8(pile.index))!
            return String(format: NSLocalizedString("%@ foundation", comment: "accessibility"),
                          suit.localizedName)
        case .tableau:
            return String(format: NSLocalizedString("Column %d", comment: "accessibility"),
                          pile.index + 1)
        }
    }

    private func value(for pile: PileID) -> String {
        let state = game.state
        switch pile.kind {
        case .stock:
            if state.stock.isEmpty {
                return state.canRecycle
                    ? NSLocalizedString("Empty, can be turned back over", comment: "accessibility")
                    : NSLocalizedString("Empty", comment: "accessibility")
            }
            return Plural.format(state.stock.count,
                                 one: NSLocalizedString("%d card face down", comment: "accessibility, singular"),
                                 other: NSLocalizedString("%d cards face down", comment: "accessibility, plural"))

        case .waste:
            guard let card = state.waste.last else {
                return NSLocalizedString("Empty", comment: "accessibility")
            }
            return card.accessibilityName

        case .foundation:
            guard let card = state.foundationTop(pile.index) else {
                return NSLocalizedString("Empty", comment: "accessibility")
            }
            return card.accessibilityName

        case .tableau:
            let column = state.tableau[pile.index]
            if column.isEmpty { return NSLocalizedString("Empty", comment: "accessibility") }
            var parts: [String] = []
            if !column.down.isEmpty {
                parts.append(String(
                    format: NSLocalizedString("%d face down", comment: "accessibility"),
                    column.down.count))
            }
            // Read the run from the top card down: that is the order the player
            // cares about, since the top card is the one they can play.
            parts.append(contentsOf: column.up.reversed().map(\.accessibilityName))
            return parts.joined(separator: ", ")
        }
    }

    /// VoiceOver's "press" on a pile does whatever a click on its top card
    /// would do.
    func performAccessibilityPress(on pile: PileID) -> Bool {
        guard !isPerformingSequence else { return false }
        let target: ClickTarget
        switch pile.kind {
        case .stock: target = .stock
        case .waste: target = .waste
        case .foundation: target = .foundation(pile.index)
        case .tableau:
            let column = game.state.tableau[pile.index]
            target = column.isEmpty ? .emptyTableau(pile.index)
                                    : .tableauCard(column: pile.index, depthFromTop: 0)
        }
        guard let move = game.autoMove(for: target) else {
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [
                                    .announcement: NSLocalizedString("No move available", comment: "accessibility"),
                                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                                 ])
            return false
        }
        return perform(move)
    }

    /// Says what happened, without moving the VoiceOver cursor. Announcing a
    /// layout change on every move would yank the cursor away from whatever the
    /// player was reading.
    func announceMove(_ record: MoveRecord) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        let description: String
        switch record.move {
        case .draw:
            description = game.state.waste.last?.accessibilityName
                ?? NSLocalizedString("No cards left", comment: "accessibility")
        case .recycle:
            description = NSLocalizedString("Turned the waste back over", comment: "accessibility")
        default:
            guard let card = record.movedCard ?? movedRunHead(record) else { return }
            description = card.accessibilityName
        }
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [
                                .announcement: description,
                                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                             ])
    }

    private func movedRunHead(_ record: MoveRecord) -> Card? {
        guard case .tableauToTableau(_, let to, let count) = record.move else { return nil }
        let up = game.state.tableau[to].up
        guard up.count >= count else { return nil }
        return up[up.count - count]
    }
}
