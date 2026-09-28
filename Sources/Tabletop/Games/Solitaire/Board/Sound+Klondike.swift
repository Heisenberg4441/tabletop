//
//  Sound+Klondike.swift
//  Which of the shared card sounds a solitaire move makes.
//

import Foundation

extension Sound {

    /// A turn off the stock is a flip, a recycle is the whole packet going
    /// back over, a foundation is a card being set down, and everything else
    /// is a card sliding along the cloth.
    static func play(for move: Move) {
        switch move {
        case .draw: play(.flip)
        case .recycle: play(.shuffle)
        case .wasteToFoundation, .tableauToFoundation: play(.place)
        default: play(.slide)
        }
    }
}
