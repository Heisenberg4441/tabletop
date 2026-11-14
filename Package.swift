// swift-tools-version:5.9
import PackageDescription

// macOS keeps the original AppKit/SceneKit application. Other hosts compile
// exactly the same rules as a headless engine used by their native shells.
let portableSources: [String] = [
    "Kit/Array.swift", "Kit/Card.swift", "Kit/RNG.swift", "Kit/BotRoster.swift", "Kit/Chips/Chips.swift",
    "App/main.swift", "Support/PortableSimd.swift", "Support/EngineServer.swift",
    "Games/Solitaire/Engine/Card+Klondike.swift", "Games/Solitaire/Engine/DealGenerator.swift",
    "Games/Solitaire/Engine/Game.swift", "Games/Solitaire/Engine/GameState.swift",
    "Games/Solitaire/Engine/Rules.swift", "Games/Solitaire/Engine/Scoring.swift",
    "Games/Solitaire/Engine/Solver.swift",
    "Games/Blackjack/Engine/BlackjackAmount.swift", "Games/Blackjack/Engine/BlackjackCards.swift",
    "Games/Blackjack/Engine/BlackjackEngine.swift", "Games/Blackjack/Engine/BlackjackRound.swift",
    "Games/Blackjack/Engine/BlackjackRules.swift", "Games/Blackjack/Engine/BlackjackShoe.swift",
    "Games/Blackjack/Engine/BlackjackStrategy.swift",
    "Games/Durak/Engine/DurakBot.swift", "Games/Durak/Engine/DurakCards.swift",
    "Games/Durak/Engine/DurakEndgameSolver.swift", "Games/Durak/Engine/DurakState.swift",
    "Games/Durak/Engine/DurakTypes.swift",
    "Games/Poker/Engine/PokerBot.swift", "Games/Poker/Engine/PokerEquity.swift",
    "Games/Poker/Engine/PokerEvaluator.swift", "Games/Poker/Engine/PokerTable.swift",
    "Games/Poker/Engine/PokerTypes.swift",
    "Games/Pool/Engine/PoolAI.swift", "Games/Pool/Engine/PoolAimGuide.swift",
    "Games/Pool/Engine/PoolGeometry.swift", "Games/Pool/Engine/PoolPhysics.swift",
    "Games/Pool/Engine/PoolRack.swift", "Games/Pool/Engine/PoolRules.swift",
    "Games/Pool/Engine/PoolTrajectory.swift", "Games/Pool/Engine/PoolTypes.swift",
    "Games/Pool/PoolMatch.swift", "Games/Pool/PoolEngineText.swift",
]

#if os(macOS)
let targetSources: [String]? = nil
#else
let targetSources: [String]? = portableSources
#endif

let package = Package(
    name: "Tabletop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tabletop", targets: ["Tabletop"])
    ],
    targets: [
        .executableTarget(name: "Tabletop", path: "Sources/Tabletop", sources: targetSources)
    ]
)
