//
//  KitTests.swift
//  Checks for the pieces every game shares, run first by `Tabletop --selftest`
//  (or alone with `--selftest kit`).
//
//  Everything here is something a game leans on without looking: that the
//  deck is the deck, that a seed means the same cards for ever, that a
//  preferences file from an older build still loads, that the first launch of
//  Tabletop brings the solitaire player's record across, and that the contract
//  the shell and the games meet at is filled in properly by every game.
//

import AppKit

@MainActor
enum KitTests {

    static func run(_ t: TestReporter) {
        deck(t)
        randomness(t)
        reporter(t)
        tablePreferences(t)
        storage(t)
        catalog(t)
        snapshots(t)
        runComponents(t)
    }

    // MARK: The deck

    private static func deck(_ t: TestReporter) {
        t.section("Deck")
        t.check("52 distinct codes", Set(Card.full.map(\.code)).count == 52)
        t.check("suit and rank survive the round trip", Card.full.allSatisfy { Card($0.suit, $0.rank) == $0 })
        t.check("the full deck is in code order", Card.full.enumerated().allSatisfy { $0.element.code == $0.offset })
        t.check("red is hearts and diamonds",
                Card.full.filter(\.isRed).count == 26 && Card(.hearts, .two).isRed && !Card(.spades, .two).isRed)
        t.check("rank values run ace low to king", Card(.clubs, .ace).value == 1 && Card(.clubs, .king).value == 13)
        let short = Card.full.filter { $0.value == 1 || $0.value >= 6 }
        t.check("a 36-card deck is six to ace in every suit", short.count == 36)
    }

    // MARK: Randomness

    private static func randomness(_ t: TestReporter) {
        t.section("Deterministic randomness")
        var a = DeterministicRNG(seed: 42)
        var b = DeterministicRNG(seed: 42)
        var c = DeterministicRNG(seed: 43)
        let first = (0..<16).map { _ in a.next() }
        t.check("the same seed gives the same stream", first == (0..<16).map { _ in b.next() })
        t.check("a different seed gives a different one", first != (0..<16).map { _ in c.next() })
        // Frozen: a seeded game in any of the collection's games — a deal
        // number, a bot's bluff, a replayable break — means the same thing on
        // every Mac for ever, which rests on this exact number.
        var frozen = DeterministicRNG(seed: 1)
        t.check("the generator itself has not changed", frozen.next() == 0xB3F2_AF6D_0FC7_10C5)
        var bounded = DeterministicRNG(seed: 7)
        t.check("bounded draws stay in bounds",
                (0..<2000).allSatisfy { _ in (0..<6).contains(bounded.next(upperBound: 6)) })
        var deckA = Card.full, deckB = Card.full
        var s1 = DeterministicRNG(seed: 99), s2 = DeterministicRNG(seed: 99)
        s1.shuffle(&deckA)
        s2.shuffle(&deckB)
        t.check("a seeded shuffle repeats exactly", deckA == deckB && deckA != Card.full)
        t.check("and loses no card", Set(deckA) == Set(Card.full))
    }

    // MARK: The reporter

    private static func reporter(_ t: TestReporter) {
        t.section("Test reporter")
        var lines: [String] = []
        let inner = TestReporter { lines.append($0) }
        inner.section("S")
        inner.check("a", true)
        inner.check("b", false)
        inner.info("i")
        t.check("it counts checks and failures", inner.checks == 2 && inner.failures == 1)
        t.check("in the format build.sh greps for",
                lines == ["S", "  ok   a", "  FAIL b", "  info i"])
    }

    // MARK: Table preferences

    private static func tablePreferences(_ t: TestReporter) {
        t.section("Table preferences")
        // What the solitaire-only app wrote, keys for settings that no longer
        // exist and all. Its table choices carry over; its sound does not.
        let legacy = #"{"drawCount":1,"table":"burgundy","backStyle":"weave","backColor":"plum","fourColorDeck":true,"soundEnabled":true,"apple":false,"windowFrame":"{{0, 74}, {1800, 1056}}"}"#
        let inherited = TablePreferences.fromLegacySolitaire(Data(legacy.utf8))
        t.check("an old solitaire preferences file still reads", inherited != nil)
        t.check("its table, card back and four-colour deck come across",
                inherited?.table == .burgundy && inherited?.backStyle == .weave
                    && inherited?.backColor == .plum && inherited?.fourColorDeck == true)
        t.check("its sound does not: the collection starts silent", inherited?.soundEnabled == false)

        let partial = try? JSONDecoder().decode(TablePreferences.self, from: Data(#"{"table":"slate"}"#.utf8))
        t.check("a file missing keys keeps what it has and defaults the rest",
                partial?.table == .slate && partial?.backStyle == .lattice && partial?.soundEnabled == false)
        t.check("the defaults are silent", TablePreferences().soundEnabled == false)
        t.check("every table is the Apple table", TablePreferences().theme.apple && Theme().apple)
        var written = TablePreferences()
        written.table = .blue
        written.soundEnabled = true
        let back = (try? JSONEncoder().encode(written)).flatMap { try? JSONDecoder().decode(TablePreferences.self, from: $0) }
        t.check("a round trip through disk is lossless", back == written)
    }

    // MARK: Storage

    private static func storage(_ t: TestReporter) {
        t.section("Storage and the move from Solitaire")
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("TabletopKitTests-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let old = root.appendingPathComponent("com.solitaire.klondike")
        let new = root.appendingPathComponent("com.tabletop.games")
        try? manager.createDirectory(at: old, withIntermediateDirectories: true)
        try? manager.createDirectory(at: new, withIntermediateDirectories: true)
        let stats = Data(#"{"drawOne":{"played":12,"won":7}}"#.utf8)
        try? stats.write(to: old.appendingPathComponent("statistics.json"))
        try? Data("{}".utf8).write(to: old.appendingPathComponent("current-game.json"))
        try? Data("{}".utf8).write(to: old.appendingPathComponent("preferences.json"))

        let copied = Storage.migrateLegacyFiles(from: old, to: new)
        t.check("the first launch copies all three solitaire files (\(copied.count))", copied.count == 3)
        t.check("under solitaire's prefixed names",
                Set(copied) == ["solitaire-preferences.json", "solitaire-statistics.json", "solitaire-current-game.json"])
        t.check("byte for byte", (try? Data(contentsOf: new.appendingPathComponent("solitaire-statistics.json"))) == stats)
        t.check("and leaves the old folder as it was",
                manager.fileExists(atPath: old.appendingPathComponent("statistics.json").path))
        try? Data("{\"drawOne\":{}}".utf8).write(to: new.appendingPathComponent("solitaire-statistics.json"))
        t.check("a later launch copies nothing", Storage.migrateLegacyFiles(from: old, to: new).isEmpty)
        t.check("so a record played since is never overwritten",
                (try? Data(contentsOf: new.appendingPathComponent("solitaire-statistics.json"))) != stats)
        let missing = root.appendingPathComponent("nowhere")
        let fresh = root.appendingPathComponent("fresh")
        try? manager.createDirectory(at: fresh, withIntermediateDirectories: true)
        t.check("a Mac that never had the solitaire app migrates nothing",
                Storage.migrateLegacyFiles(from: missing, to: fresh).isEmpty)
        t.check("each game's files carry its id", Storage.fileName("bankroll.json", for: .poker) == "poker-bankroll.json")

        // The whole first launch, end to end, in a scratch Application
        // Support: the old folder is found beside the new one, and the table
        // choices come out of the old preferences file into a file of their
        // own — without the sound.
        let base = root.appendingPathComponent("Application Support")
        let legacyFolder = base.appendingPathComponent(Storage.legacyBundleIdentifier)
        try? manager.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try? Data(#"{"table":"blue","backColor":"crimson","soundEnabled":true,"drawCount":3}"#.utf8)
            .write(to: legacyFolder.appendingPathComponent("preferences.json"))
        let appFolder = Storage.prepareDirectory(in: base)
        t.check("the app's folder is named for the new bundle", appFolder.lastPathComponent == "com.tabletop.games")
        let previous = Storage.directory
        Storage.use(directory: appFolder)
        let firstLaunch = TablePreferences.load()
        t.check("the first launch dresses the table as the solitaire player left it",
                firstLaunch.table == .blue && firstLaunch.backColor == .crimson && !firstLaunch.soundEnabled)
        t.check("and keeps it in a file of its own", Storage.exists(TablePreferences.fileName))
        Storage.use(directory: previous)
        t.check("the harness never writes to Application Support",
                !TabletopEnvironment.isHarness || !Storage.directory.path.contains("Application Support"))
    }

    // MARK: The contract

    private static func catalog(_ t: TestReporter) {
        t.section("Game catalog")
        let infos = GameCatalog.all.map { $0.info }
        t.check("one game per id, in library order", infos.map(\.id) == GameID.allCases)
        t.check("shortcuts are ⌘1 to ⌘5 in order",
                infos.map(\.keyEquivalent) == (1...GameID.allCases.count).map(String.init))
        t.check("every game has a title, a subtitle and a players line",
                infos.allSatisfy { !$0.title.isEmpty && !$0.subtitle.isEmpty && !$0.detail.isEmpty })
        let missing = infos.filter { NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: nil) == nil }
        t.check("every symbol exists \(missing.map(\.symbolName))", missing.isEmpty)
        t.check("every game explains itself", GameCatalog.all.allSatisfy { !$0.howToPlay.isEmpty })
        t.check("titles are unique", Set(infos.map(\.title)).count == infos.count)

        // Every cover, painted small, has to be a picture: a blank or a flat
        // fill means `drawArtwork` drew nothing or drew outside its rect.
        var blank: [String] = []
        for type in GameCatalog.all {
            let size = CGSize(width: 160, height: 100)
            guard let image = LibraryArtwork.image(for: type.info.id, size: size, scale: 1),
                  distinctColours(in: image) > 24 else {
                blank.append(type.info.id.rawValue)
                continue
            }
        }
        LibraryArtwork.removeAll()
        t.check("every cover is a picture \(blank)", blank.isEmpty)
    }

    // MARK: Snapshots

    /// `LayerSnapshot` decides from the layer whether to turn the bitmap over,
    /// and getting that wrong silently produces upside-down screenshots. A red
    /// band along the top of a view has to come out along the top of the PNG,
    /// flipped view or not.
    private static func snapshots(_ t: TestReporter) {
        t.section("Off-screen snapshots")
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        for flipped in [true, false] {
            let size = CGSize(width: 40, height: 40)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            let view: NSView = flipped ? Flipped() : NSView()
            view.frame = NSRect(origin: .zero, size: size)
            view.wantsLayer = true
            window.contentView = view
            let band = NSView(frame: NSRect(x: 0, y: flipped ? 0 : 30, width: 40, height: 10))
            band.wantsLayer = true
            band.layer?.backgroundColor = NSColor.red.cgColor
            view.addSubview(band)
            let image = LayerSnapshot.image(of: view, size: size, scale: 1)
            let top = image.flatMap { pixel(in: $0, x: 20, y: 2) }
            let bottom = image.flatMap { pixel(in: $0, x: 20, y: 37) }
            t.check("a band at the top of a \(flipped ? "flipped" : "plain") view is at the top of the picture",
                    (top?.red ?? 0) > 200 && (bottom?.red ?? 255) < 60)
        }
    }

    // MARK: Pixels

    static func pixel(in image: CGImage, x: Int, y: Int) -> (red: Int, green: Int, blue: Int)? {
        guard let data = rgba(image) else { return nil }
        let i = (y * image.width + x) * 4
        guard i + 3 < data.count else { return nil }
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    private static func distinctColours(in image: CGImage) -> Int {
        guard let data = rgba(image) else { return 0 }
        var seen = Set<UInt32>()
        var i = 0
        while i + 3 < data.count {
            seen.insert(UInt32(data[i] >> 3) << 10 | UInt32(data[i + 1] >> 3) << 5 | UInt32(data[i + 2] >> 3))
            i += 4 * 7
        }
        return seen.count
    }

    /// The image redrawn as plain RGBA bytes, top row first.
    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }
}
