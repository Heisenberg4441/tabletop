//
//  Storage.swift
//  Everything the app keeps on disk: one JSON file per thing, in one folder.
//
//  ~/Library/Application Support/com.tabletop.games/ holds the whole
//  collection's state. Each game owns the files whose names start with its
//  identifier — `solitaire-statistics.json`, `poker-bankroll.json` — so two
//  games can never trample each other, and a game can be reset by deleting its
//  own files without touching anyone else's. The shared files (the table
//  preferences, the window) have no prefix. `Storage.fileName(_:for:)` builds
//  the prefixed names so nobody has to spell the convention by hand.
//
//  Plain JSON rather than UserDefaults: a bundled app built without Xcode has a
//  bundle identifier that tools sometimes disagree about, and a readable file in
//  Application Support never surprises anyone.
//

import AppKit

enum Storage {

    static let bundleIdentifier = "com.tabletop.games"

    /// Where the app kept its files when it was only a solitaire game.
    static let legacyBundleIdentifier = "com.solitaire.klondike"

    /// The old solitaire files and the names they go by now. Solitaire's files
    /// are prefixed like every other game's, so the one-time copy renames them
    /// on the way across.
    static let legacyRenames: [(old: String, new: String)] = [
        ("preferences.json", "solitaire-preferences.json"),
        ("statistics.json", "solitaire-statistics.json"),
        ("current-game.json", "solitaire-current-game.json"),
    ]

    /// ~/Library/Application Support/<bundle id>/ — created, and filled from
    /// the old solitaire folder if this is the first launch, on first use.
    static var directory: URL {
        if let chosen { return chosen }
        let url = prepareDirectory(in: applicationSupport)
        chosen = url
        return url
    }

    /// The app's folder inside `base`, created if need be and filled from the
    /// old solitaire folder beside it on the first launch. `base` is
    /// Application Support in the app, and a scratch folder in the self-test.
    static func prepareDirectory(in base: URL) -> URL {
        let url = base.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        migrateLegacyFiles(
            from: base.appendingPathComponent(legacyBundleIdentifier, isDirectory: true), to: url)
        return url
    }

    private static var chosen: URL?

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    // MARK: Files

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let url = directory.appendingPathComponent(name)
        guard let data = try? JSONEncoder().encode(value) else { return }
        // Atomic, so a crash mid-write cannot leave a half-written save that
        // refuses to load next launch.
        try? data.write(to: url, options: .atomic)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    // MARK: Migration

    /// Copies the solitaire-only app's files across, once.
    ///
    /// "Once" is decided by the destination rather than by a flag: the copy
    /// happens only while the new folder holds no files at all. The first
    /// launch of Tabletop finds it empty and brings the player's statistics and
    /// game in progress over; every launch after that finds files there and
    /// leaves both folders alone. The old folder is copied from, never moved or
    /// deleted, so running an old build of the solitaire app afterwards still
    /// finds everything where it left it.
    ///
    /// Returns the names written, for the self-test.
    @discardableResult
    static func migrateLegacyFiles(from old: URL, to new: URL) -> [String] {
        let manager = FileManager.default
        let existing = (try? manager.contentsOfDirectory(atPath: new.path)) ?? []
        guard existing.allSatisfy({ $0.hasPrefix(".") }) else { return [] }
        var copied: [String] = []
        for (oldName, newName) in legacyRenames {
            let source = old.appendingPathComponent(oldName)
            guard manager.fileExists(atPath: source.path) else { continue }
            if (try? manager.copyItem(at: source, to: new.appendingPathComponent(newName))) != nil {
                copied.append(newName)
            }
        }
        return copied
    }

    // MARK: The harness

    /// Points every load and save at a folder of the caller's choosing.
    ///
    /// For the command-line harness and the self-tests only. `--playtest`,
    /// `--controls` and `--shot` all build real games, and a real game saves
    /// on the way out — which, pointed at Application Support, would quietly
    /// overwrite the player's game in progress with a test deal every time
    /// build.sh ran.
    static func use(directory url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        chosen = url
    }

    /// A fresh, empty folder under the temporary directory, removed again when
    /// the process exits.
    static func useTemporaryDirectory() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tabletop-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                                    isDirectory: true)
        use(directory: url)
        temporaryDirectory = url
        atexit {
            if let url = Storage.temporaryDirectory {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static var temporaryDirectory: URL?
}
