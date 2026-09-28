//
//  DurakTrumpPill.swift
//  "Trump ♦" in the window's top strip, the suit in its own colour.
//
//  The trump suit is the one fact every decision in durak turns on, so its
//  pill names the suit in words and symbol together — «Козырь ♦» — and paints
//  a red suit red, as it is printed on the cards: a grey symbol beside the
//  word reads as decoration and is overlooked.
//
//  The kit's pills are drawn by the window, in one colour, and have no way
//  to colour part of their text (see KIT GAPS in the build notes). So the
//  pill is posted as plain "Trump ♦" — correct and legible on its own — and
//  then, once the window has drawn it, the suit is tinted in place. If the
//  window ever draws its pills differently the tint simply finds nothing to
//  touch, and the plain pill stays.
//

import AppKit

@MainActor
enum DurakTrumpPill {

    static let id = "trump"

    /// The pill for `trump`: gold while the first bout is on, when the suit
    /// is news.
    static func item(for trump: Suit, emphasized: Bool) -> StatusPillItem {
        StatusPillItem(id: id, text: text(for: trump), symbolName: nil, isEmphasized: emphasized)
    }

    /// "Trump ♦". The suit's character is asked for as text (U+FE0E), never
    /// as the colour emoji some fonts would otherwise substitute.
    static func text(for trump: Suit) -> String {
        String(format: NSLocalizedString("Trump %@", comment: "durak pill: the trump suit's symbol («Козырь ♦»)"),
               glyph(trump))
    }

    static func glyph(_ suit: Suit) -> String { suit.symbol + "\u{FE0E}" }

    /// A card's red, lifted a little to read on dark glass.
    static let red = NSColor(srgbRed: 0.97, green: 0.36, blue: 0.34, alpha: 1)

    /// Tints the suit of the trump pill showing in `window`, once the window
    /// has put up what was just posted — on the next turn of the main queue,
    /// after the strip's own update.
    static func paint(_ trump: Suit?, in window: NSWindow?) {
        guard let trump, let window else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { _ = tint(trump, in: window) }
        }
    }

    /// The same, at once. True if a pill was found and tinted.
    @discardableResult
    static func tint(_ trump: Suit, in window: NSWindow) -> Bool {
        guard let root = window.contentView else { return false }
        var found = false
        for pill in pills(in: root) where pill.item.id == id {
            pill.setAccessibilityLabel(String(format: NSLocalizedString("Trump: %@", comment: "durak pill, accessibility: the trump suit"),
                                              trump.localizedName))
            guard let label = labels(in: pill).first(where: { $0.stringValue == pill.item.text }) else { continue }
            found = true
            guard trump.isRed else { continue }
            let text = pill.item.text
            let styled = NSMutableAttributedString(string: text, attributes: [
                .font: label.font ?? NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: label.textColor ?? Palette.textPrimary,
            ])
            // The glyph with its text-style selector: the pair is one
            // character, and the bare suit would not be found inside it.
            let range = (text as NSString).range(of: glyph(trump), options: .backwards)
            if range.location != NSNotFound { styled.addAttribute(.foregroundColor, value: red, range: range) }
            label.attributedStringValue = styled
        }
        return found
    }

    private static func pills(in view: NSView) -> [StatusPillView] {
        if let pill = view as? StatusPillView { return [pill] }
        return view.subviews.flatMap { pills(in: $0) }
    }

    private static func labels(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
    }
}
