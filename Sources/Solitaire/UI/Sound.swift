//
//  Sound.swift
//  Card sounds, synthesised at launch — and off unless the player asks for them.
//
//  The app ships no audio files. Each effect is shaped noise written into an
//  in-memory WAV, which costs a couple of milliseconds and a few kilobytes
//  rather than a bundle full of assets.
//
//  Two things matter more than realism here. First, the envelope: a sharp
//  attack reads as a slap, which is unpleasant at any volume, so every effect
//  fades in and out over a raised cosine and has no edge anywhere for the ear
//  to catch on. Second, the spectrum: paper is a narrow mid-band rustle, not
//  broadband white noise, so the noise is band-limited by subtracting a slow
//  low-pass from a faster one. The result is a page turn rather than a knock.
//

import AppKit

enum SoundEffect {
    case deal, place, flip, slide, shuffle, win
}

enum Sound {

    /// Off by default. A card game that starts making noise the moment it opens
    /// is a game people close.
    static var isEnabled = false

    private static var cache: [String: Data] = [:]
    private static var players: [NSSound] = []

    /// Deliberately quiet. These are texture, not signals.
    private static let volume: Float = 0.16

    static func play(for move: Move) {
        switch move {
        case .draw: play(.flip)
        case .recycle: play(.shuffle)
        case .wasteToFoundation, .tableauToFoundation: play(.place)
        default: play(.slide)
        }
    }

    static func play(_ effect: SoundEffect) {
        guard isEnabled else { return }
        let key = String(describing: effect)
        let data: Data
        if let cached = cache[key] {
            data = cached
        } else {
            data = synthesize(effect)
            cache[key] = data
        }
        guard let sound = NSSound(data: data) else { return }
        sound.volume = volume
        // Hold a reference until it finishes; NSSound stops if it is released.
        players.append(sound)
        if players.count > 8 { players.removeFirst(players.count - 8) }
        sound.play()
    }

    // MARK: Synthesis

    private static let sampleRate = 44_100.0

    private static func synthesize(_ effect: SoundEffect) -> Data {
        switch effect {
        case .flip:    return rustle(duration: 0.095, brightness: 0.13, level: 0.50)
        case .deal:    return rustle(duration: 0.110, brightness: 0.12, level: 0.52)
        case .slide:   return rustle(duration: 0.145, brightness: 0.10, level: 0.46)
        case .place:   return rustle(duration: 0.125, brightness: 0.11, level: 0.54)
        case .shuffle: return rustle(duration: 0.340, brightness: 0.12, level: 0.48)
        case .win:     return chime()
        }
    }

    /// Band-limited noise under a raised-cosine envelope: a sheet of paper
    /// moving against another sheet of paper.
    ///
    /// `brightness` is the coefficient of the fast one-pole filter — higher is
    /// more air, lower is more of a soft brush. The slow filter underneath is
    /// subtracted rather than mixed, which removes the low rumble that would
    /// otherwise make every effect sound like a thump.
    private static func rustle(duration: Double, brightness: Double, level: Double) -> Data {
        let count = Int(sampleRate * duration)
        guard count > 8 else { return wav([]) }
        var samples = [Int16](repeating: 0, count: count)
        var rng = DeterministicRNG(seed: UInt64(duration * 1_000_000) &* 31 &+ 7)

        var fast = 0.0
        var slow = 0.0
        var texture = 0.0

        for i in 0..<count {
            let position = Double(i) / Double(count - 1)
            let white = Double(rng.next() >> 11) / Double(1 << 52) - 1.0

            fast += brightness * (white - fast)
            slow += 0.010 * (white - slow)
            let band = fast - slow

            // Hann window: zero slope at both ends, so there is no onset click
            // and no cut-off tail. This is the whole difference between a
            // rustle and a slap.
            let envelope = 0.5 - 0.5 * cos(2 * .pi * position)

            // A slow random wobble on top. Without it the noise reads as a
            // synthetic hiss; with it, as something physical moving.
            texture += 0.004 * (white - texture)
            let wobble = 0.7 + min(0.6, abs(texture) * 9)

            let value = band * envelope * wobble * level
            samples[i] = Int16(max(-1, min(1, value)) * 8_200)
        }
        return wav(samples)
    }

    /// A soft two-note bell for the win. Sine partials with a long decay and
    /// the same fade-in as everything else.
    private static func chime() -> Data {
        let duration = 1.4
        let count = Int(sampleRate * duration)
        var samples = [Double](repeating: 0, count: count)
        let notes: [(freq: Double, start: Double, level: Double)] = [
            (523.25, 0.00, 0.16),
            (783.99, 0.16, 0.13),
            (1046.50, 0.32, 0.10),
        ]
        for note in notes {
            let begin = Int(note.start * sampleRate)
            guard begin < count else { continue }
            for i in begin..<count {
                let t = Double(i - begin) / sampleRate
                let attack = min(1, t * 60)          // ~17 ms, well clear of a click
                let envelope = exp(-2.4 * t) * attack
                samples[i] += sin(2 * .pi * note.freq * t) * envelope * note.level
                samples[i] += sin(2 * .pi * note.freq * 2.01 * t) * envelope * note.level * 0.18
            }
        }
        return wav(samples.map { Int16(max(-1, min(1, $0)) * 16_000) })
    }

    private static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        let byteCount = samples.count * 2
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                    // PCM header size
        append(UInt16(1))                     // format: PCM
        append(UInt16(1))                     // channels
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)        // byte rate
        append(UInt16(2))                     // block align
        append(UInt16(16))                    // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        for sample in samples { append(sample) }
        return data
    }

    /// Writes every effect to disk so they can be listened to without playing
    /// a game. `Solitaire --sounds <directory>`.
    static func exportAll(to directory: String) -> Int32 {
        let effects: [(String, SoundEffect)] = [
            ("flip", .flip), ("deal", .deal), ("slide", .slide),
            ("place", .place), ("shuffle", .shuffle), ("win", .win),
        ]
        for (name, effect) in effects {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).wav")
            do {
                try synthesize(effect).write(to: url)
                print("wrote \(url.path)")
            } catch {
                FileHandle.standardError.write(Data("sounds: \(error)\n".utf8))
                return 1
            }
        }
        return 0
    }
}
