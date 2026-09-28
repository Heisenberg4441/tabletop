//
//  TablePreferences.swift
//  The choices that belong to the table rather than to any one game.
//
//  The cloth, the card backs, the four-colour deck and the sound are the same
//  wherever the player sits down: picking burgundy felt in Durak and walking
//  over to Blackjack should find burgundy felt there too. So they live here,
//  in one file of their own, and every game reads them from `current` and
//  listens for `didChange` to re-dress its table the moment the player picks
//  something new in the View menu — no new deal, no reopening the game.
//
//  Only the app writes them (the View menu is the one place they change), and
//  games only read. A game with a choice that means something only to itself
//  keeps it in a file of its own, named with its id — see `Storage`.
//

import AppKit

struct TablePreferences: Codable, Equatable {
    var table: TableColor = .green
    var backStyle: CardBackStyle = .lattice
    var backColor: CardBackColor = .navy
    /// The standard accommodation for players who cannot tell red from black.
    var fourColorDeck: Bool = false
    /// Off by default, and never switched on by anything but the player
    /// choosing View ▸ Sound. Some people find sharp interface sounds
    /// physically painful; a table that starts making noise on its own is not
    /// one they can sit at.
    var soundEnabled: Bool = false

    static let fileName = "table-preferences.json"

    /// Posted on the main thread after `current` changes. The object is nil
    /// and there is no user info: read `TablePreferences.current` for the new
    /// values, and `theme` for what a card table should now look like.
    static let didChange = Notification.Name("TablePreferencesDidChange")

    init() {}

    /// Decoded key by key, with a default for anything missing, for the same
    /// reason every preferences file in the app is: the synthesised decoder
    /// throws on the first absent key, and answering that with a fresh file
    /// would reset every choice the player made the day a setting is added.
    ///
    /// A key that is present but unreadable — a cloth colour a later build
    /// added and this one does not know, a value of the wrong type — falls
    /// back to its default on its own, for the same reason: one bad value
    /// must not cost the player every other choice in the file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(type, forKey: key)) ?? nil) ?? fallback
        }
        table = value(TableColor.self, .table, .green)
        backStyle = value(CardBackStyle.self, .backStyle, .lattice)
        backColor = value(CardBackColor.self, .backColor, .navy)
        fourColorDeck = value(Bool.self, .fourColorDeck, false)
        soundEnabled = value(Bool.self, .soundEnabled, false)
    }

    /// What a card table should look like under these choices. Always the
    /// Apple table — the whole collection is dressed that way.
    var theme: Theme {
        var theme = Theme()
        theme.table = table
        theme.backStyle = backStyle
        theme.backColor = backColor
        theme.fourColorDeck = fourColorDeck
        theme.apple = true
        return theme
    }

    // MARK: The live copy

    private static var loaded: TablePreferences?

    /// The preferences in force. Assigning saves them, switches the sound on
    /// or off to match, and posts `didChange` — in that order, so an observer
    /// that reads `current` sees what was just chosen.
    static var current: TablePreferences {
        get {
            if let loaded { return loaded }
            let preferences = load()
            loaded = preferences
            Sound.isEnabled = preferences.soundEnabled
            return preferences
        }
        set {
            let old = current
            loaded = newValue
            Sound.isEnabled = newValue.soundEnabled
            guard newValue != old else { return }
            newValue.save()
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Forgets the live copy so the next read comes from disk. For the
    /// harness, which points `Storage` somewhere new after launch.
    static func reload() {
        loaded = nil
        _ = current
    }

    // MARK: Disk

    func save() {
        Storage.save(self, to: Self.fileName)
    }

    /// The saved file; failing that, the choices the player made back when the
    /// app was only a solitaire game; failing that, the defaults.
    static func load() -> TablePreferences {
        if let saved = Storage.load(TablePreferences.self, from: fileName) {
            return saved
        }
        if let data = try? Data(contentsOf: Storage.directory.appendingPathComponent(legacyFileName)),
           let inherited = fromLegacySolitaire(data) {
            inherited.save()
            return inherited
        }
        return TablePreferences()
    }

    /// The solitaire-only app kept these choices in its own preferences file,
    /// which `Storage` has already copied across under its new name.
    static let legacyFileName = "solitaire-preferences.json"

    /// Lifts the table choices out of an old solitaire preferences file.
    ///
    /// Everything visual comes across. The sound does not, deliberately: the
    /// old app's switch was a choice about one quiet card game, and inheriting
    /// it would have a brand-new collection of games start making noise on
    /// first launch without the player having asked this app for anything.
    /// It starts silent, like every table, and is one menu item away.
    static func fromLegacySolitaire(_ data: Data) -> TablePreferences? {
        guard var inherited = try? JSONDecoder().decode(TablePreferences.self, from: data) else {
            return nil
        }
        inherited.soundEnabled = false
        return inherited
    }
}
