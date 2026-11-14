#if !os(macOS)
import Foundation

enum EngineError: Error {
    case invalidRequest(String)
    case unsupportedGame(String)
}

final class EngineServer {
    private var solitaire: Game?
    private var blackjack: BlackjackEngine?
    private var durak: DurakState?
    private var durakDifficulty = DurakDifficulty.normal
    private var poker: PokerTable?
    private var pool: PoolMatch?
    private let geometry = PoolTableGeometry.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func handle(_ request: [String: Any]) throws -> [String: Any] {
        guard let game = request["game"] as? String else { throw EngineError.invalidRequest("Missing game") }
        let action = request["action"] as? String ?? "state"
        switch game {
        case "solitaire": return try handleSolitaire(action, request)
        case "blackjack": return try handleBlackjack(action, request)
        case "durak": return try handleDurak(action, request)
        case "poker": return try handlePoker(action, request)
        case "pool": return try handlePool(action, request)
        default: throw EngineError.unsupportedGame(game)
        }
    }

    private func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: encoder.encode(value), options: .fragmentsAllowed)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try decoder.decode(type, from: data)
    }

    private func int(_ request: [String: Any], _ key: String, _ fallback: Int = 0) -> Int {
        (request[key] as? NSNumber)?.intValue ?? request[key] as? Int ?? fallback
    }
    private func uint(_ request: [String: Any], _ key: String, _ fallback: UInt64 = 0) -> UInt64 {
        if let value = request[key] as? NSNumber { return value.uint64Value }
        if let value = request[key] as? String { return UInt64(value) ?? fallback }
        return fallback
    }
    private func double(_ request: [String: Any], _ key: String, _ fallback: Double = 0) -> Double {
        (request[key] as? NSNumber)?.doubleValue ?? fallback
    }
    private func string(_ request: [String: Any], _ key: String, _ fallback: String = "") -> String {
        request[key] as? String ?? fallback
    }
    private func bool(_ request: [String: Any], _ key: String, _ fallback: Bool = false) -> Bool {
        (request[key] as? NSNumber)?.boolValue ?? fallback
    }
    private func card(_ request: [String: Any], _ key: String = "card") -> Card? {
        guard request.keys.contains(key) else { return nil }
        return Card(code: UInt8(clamping: int(request, key)))
    }
    private func response<S: Encodable, T: Encodable>(_ game: String, state: S, saved: T, extra: [String: Any] = [:]) throws -> [String: Any] {
        var result: [String: Any] = ["ok": true, "game": game, "state": try object(state), "saved": try object(saved)]
        for (key, value) in extra { result[key] = value }
        return result
    }

    // MARK: Solitaire

    private func handleSolitaire(_ action: String, _ request: [String: Any]) throws -> [String: Any] {
        if action == "restore", let saved = request["saved"] {
            solitaire = Game(restoring: try decode(SavedGame.self, saved))
        } else if action == "new" || solitaire == nil {
            var options = GameOptions()
            options.drawCount = max(1, min(3, int(request, "drawCount", 1)))
            options.scoring = ScoringMode(rawValue: string(request, "scoring", "standard")) ?? .standard
            options.redealLimit = request["redealLimit"] is NSNull ? nil : (request.keys.contains("redealLimit") ? int(request, "redealLimit") : GameOptions.defaultRedealLimit(scoring: options.scoring, drawCount: options.drawCount))
            let deal = int(request, "dealNumber", 0)
            solitaire = Game(dealNumber: deal > 0 ? deal : DealNumber.random(), options: options)
        } else if let game = solitaire {
            switch action {
            case "draw": game.perform(.draw(count: game.state.drawCount))
            case "recycle": game.perform(.recycle)
            case "undo": game.undo()
            case "redo": game.redo()
            case "restart": game.restart()
            case "autoFinish":
                var count = 0
                while let move = game.state.autoFinishMove(), count < 200 { game.perform(move); count += 1 }
            case "click":
                let target = string(request, "target")
                let move: Move?
                switch target {
                case "stock": move = game.autoMove(for: .stock)
                case "waste": move = game.autoMove(for: .waste)
                case "tableau": move = game.autoMove(for: .tableauCard(column: int(request, "column"), depthFromTop: int(request, "depth")))
                default: move = nil
                }
                if let move { game.perform(move) }
            case "move": if let move = solitaireMove(request) { game.perform(move) }
            case "hint":
                if let move = game.hint() { game.perform(move) }
            case "state": break
            default: throw EngineError.invalidRequest("Unknown solitaire action \(action)")
            }
        }
        guard let game = solitaire else { throw EngineError.invalidRequest("No solitaire game") }
        return try response("solitaire", state: game.state, saved: game.saved, extra: [
            "score": game.displayScore, "moves": game.actionCount, "elapsed": game.elapsed,
            "won": game.isWon, "canUndo": game.canUndo, "canRedo": game.canRedo,
        ])
    }

    private func solitaireMove(_ request: [String: Any]) -> Move? {
        switch string(request, "kind") {
        case "wasteFoundation": return .wasteToFoundation
        case "wasteTableau": return .wasteToTableau(column: int(request, "column"))
        case "tableauFoundation": return .tableauToFoundation(column: int(request, "column"))
        case "tableauTableau": return .tableauToTableau(from: int(request, "from"), to: int(request, "to"), count: int(request, "count", 1))
        case "foundationTableau": return .foundationToTableau(suit: Suit(rawValue: UInt8(int(request, "suit"))) ?? .clubs, column: int(request, "column"))
        case "draw": return .draw(count: int(request, "count", 1))
        case "recycle": return .recycle
        default: return nil
        }
    }

    // MARK: Blackjack

    private func handleBlackjack(_ action: String, _ request: [String: Any]) throws -> [String: Any] {
        if action == "restore", let saved = request["saved"] {
            blackjack = try decode(BlackjackEngine.self, saved)
        } else if action == "new" || blackjack == nil {
            var rules = BlackjackRules()
            rules.decks = int(request, "decks", rules.decks)
            rules.dealerHitsSoft17 = bool(request, "hitSoft17", rules.dealerHitsSoft17)
            blackjack = BlackjackEngine(rules: rules, seed: uint(request, "seed", UInt64.random(in: 1...UInt64.max)))
        } else if var game = blackjack {
            switch action {
            case "bet": game.addToBet(int(request, "amount"))
            case "removeBet": game.removeFromBet(int(request, "amount"))
            case "clearBet": game.clearBet()
            case "rebet": game.rebet()
            case "deal": game.deal()
            case "insurance": game.decideInsurance(take: bool(request, "take"))
            case "advance": game.advance()
            case "collect": game.collect()
            case "resetBankroll": game.resetBankroll()
            case "hit", "stand", "double", "split", "surrender":
                if let choice = BlackjackAction(rawValue: action) { game.perform(choice) }
            case "state": break
            default: throw EngineError.invalidRequest("Unknown blackjack action \(action)")
            }
            blackjack = game
        }
        guard let game = blackjack else { throw EngineError.invalidRequest("No blackjack game") }
        return try response("blackjack", state: game, saved: game, extra: [
            "phase": game.phase.rawValue, "needsAdvance": game.needsAdvance,
            "legalActions": game.legalActions().map(\.rawValue).sorted(),
            "bankroll": try object(game.bankroll), "pendingBet": game.pendingBet,
            "isBroke": game.isBroke,
        ])
    }

    // MARK: Durak

    private func handleDurak(_ action: String, _ request: [String: Any]) throws -> [String: Any] {
        if action == "restore", let saved = request["saved"] {
            durak = try decode(DurakState.self, saved)
            durakDifficulty = DurakDifficulty(rawValue: string(request, "difficulty", "normal")) ?? .normal
        } else if action == "new" || durak == nil {
            let rules = DurakRules(playerCount: max(2, min(4, int(request, "players", 2))),
                                   variant: DurakVariant(rawValue: string(request, "variant", "podkidnoy")) ?? .podkidnoy)
            durakDifficulty = DurakDifficulty(rawValue: string(request, "difficulty", "normal")) ?? .normal
            durak = DurakState.newGame(rules: rules, seed: uint(request, "seed", UInt64.random(in: 1...UInt64.max))).state
        } else if var game = durak {
            switch action {
            case "play":
                if let choice = try durakAction(request) { _ = try game.apply(choice, by: 0) }
            case "bot":
                if let actor = game.actor, actor != 0 {
                    let choice = DurakBot(durakDifficulty).decide(in: game, seat: actor)
                    _ = try game.apply(choice, by: actor)
                }
            case "state": break
            default: throw EngineError.invalidRequest("Unknown durak action \(action)")
            }
            durak = game
        }
        guard let game = durak else { throw EngineError.invalidRequest("No durak game") }
        return try response("durak", state: game, saved: game, extra: [
            "legalActions": object(game.legalActions(for: 0)), "over": game.isOver,
        ])
    }

    private func durakAction(_ request: [String: Any]) throws -> DurakAction? {
        switch string(request, "kind") {
        case "attack": return card(request).map(DurakAction.attack)
        case "defend":
            if let chosen = card(request), let attack = card(request, "on") { return .defend(chosen, on: attack) }
            return nil
        case "transfer": return card(request).map(DurakAction.transfer)
        case "take": return .take
        case "pass": return .pass
        default: return nil
        }
    }

    // MARK: Poker

    private func handlePoker(_ action: String, _ request: [String: Any]) throws -> [String: Any] {
        if action == "restore", let saved = request["saved"] {
            poker = try decode(PokerTable.self, saved)
        } else if action == "new" || poker == nil {
            let config = PokerTableConfig(mode: PokerMode(rawValue: string(request, "mode", "tournament")) ?? .tournament,
                                          opponents: max(1, min(5, int(request, "opponents", 5))),
                                          difficulty: PokerDifficulty(rawValue: string(request, "difficulty", "standard")) ?? .standard)
            poker = PokerTable(config: config, seed: uint(request, "seed", UInt64.random(in: 1...UInt64.max)))
            poker?.startHand()
        } else if var game = poker {
            switch action {
            case "startHand": game.startHand()
            case "advance": game.advance()
            case "bot":
                if let seat = game.toAct, seat != 0 { try game.apply(PokerBot.decide(table: game, seat: seat).action) }
            case "play": try game.apply(pokerAction(request))
            case "topUp": game.topUp(seat: 0)
            case "state": break
            default: throw EngineError.invalidRequest("Unknown poker action \(action)")
            }
            poker = game
        }
        guard let game = poker else { throw EngineError.invalidRequest("No poker game") }
        var extra: [String: Any] = ["phase": game.phase.rawValue, "street": game.street.rawValue, "pot": game.potTotal]
        if let options = game.options() {
            extra["options"] = [
                "seat": options.seat, "canFold": options.canFold, "canCheck": options.canCheck,
                "canCall": options.canCall, "callAmount": options.callAmount,
                "canBet": options.canBet, "canRaise": options.canRaise,
                "minTotal": options.minTotal, "maxTotal": options.maxTotal,
                "currentBet": options.currentBet, "playerBet": options.playerBet, "pot": options.pot,
            ]
        }
        return try response("poker", state: game, saved: game, extra: extra)
    }

    private func pokerAction(_ request: [String: Any]) -> PokerAction {
        switch string(request, "kind") {
        case "fold": return .fold
        case "check": return .check
        case "call": return .call
        case "bet": return .bet(int(request, "total"))
        case "raise": return .raise(int(request, "total"))
        default: return .allIn
        }
    }

    // MARK: Pool

    private func handlePool(_ action: String, _ request: [String: Any]) throws -> [String: Any] {
        var replay: [String: Any]? = nil
        if action == "restore", let saved = request["saved"] {
            pool = try decode(PoolSavedGame.self, saved).match
        } else if action == "new" || pool == nil {
            var options = PoolOptions()
            options.mode = PoolMode(rawValue: string(request, "mode", "eightBall")) ?? .eightBall
            options.difficulty = PoolDifficulty(rawValue: string(request, "difficulty", "medium")) ?? .medium
            pool = PoolMatch.start(options, seed: uint(request, "seed", UInt64.random(in: 1...UInt64.max)),
                                   breaker: PoolSeat.you, opponentName: "Anna")
        } else if var game = pool {
            switch action {
            case "shoot":
                var shot = PoolShot(aim: double(request, "aim"), power: double(request, "power", 0.6),
                                    tipSide: double(request, "tipSide"), tipVertical: double(request, "tipVertical"))
                shot.isBreak = game.rules.isBreakShot
                replay = try playPoolShot(&game, shot)
            case "bot":
                let decision = PoolAI.decide(table: game.table, rules: game.rules, difficulty: game.options.difficulty,
                                             seed: game.decisionSeed, geometry: geometry)
                if let spot = decision.placement, game.rules.ballInHand != nil {
                    PoolRules.placeCueBall(on: &game.table, preferring: spot, kitchen: game.rules.ballInHand == .kitchen, geometry: geometry)
                }
                replay = try playPoolShot(&game, decision.shot)
            case "place":
                let point = SIMD2(double(request, "x"), double(request, "y"))
                if PoolRules.isValidPlacement(point, game.rules, table: game.table, geometry: geometry) {
                    PoolRules.placeCueBall(on: &game.table, preferring: point, kitchen: game.rules.ballInHand == .kitchen, geometry: geometry)
                }
            case "state": break
            default: throw EngineError.invalidRequest("Unknown pool action \(action)")
            }
            pool = game
        }
        guard let game = pool else { throw EngineError.invalidRequest("No pool game") }
        var extra: [String: Any] = ["over": game.isOver, "computer": game.shooterIsComputer]
        if let replay { extra["replay"] = replay }
        return try response("pool", state: PoolSavedGame(game, aim: 0), saved: PoolSavedGame(game, aim: 0), extra: extra)
    }

    private func playPoolShot(_ game: inout PoolMatch, _ shot: PoolShot) throws -> [String: Any] {
        let result = PoolPhysics.simulate(shot, from: game.table, geometry: geometry, record: true)
        let outcome = PoolRules.evaluate(result, before: game.table, state: game.rules, geometry: geometry)
        let summary = game.apply(outcome, result: result)
        var tracks: [[String: Any]] = []
        if let trajectory = result.trajectory {
            for track in trajectory.tracks {
                let keys = track.keys.map { key -> [String: Any] in
                    ["time": key.time, "x": key.position.x, "y": key.position.y, "drop": key.drop,
                     "q": [key.orientation.vector.x, key.orientation.vector.y, key.orientation.vector.z, key.orientation.vector.w]]
                }
                tracks.append(["number": track.number, "keys": keys, "pocketTime": track.pocketTime])
            }
        }
        return ["duration": result.trajectory?.duration ?? 0, "tracks": tracks,
                "pocketed": result.pocketed.map(\.ball), "remarks": summary.remarks,
                "foul": summary.foul.map { String(describing: $0) } ?? NSNull(),
                "continues": summary.continues]
    }
}
#endif
