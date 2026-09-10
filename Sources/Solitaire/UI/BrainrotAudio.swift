//
//  BrainrotAudio.swift
//  The soundtrack for brainrot mode: two bars of dubstep, synthesised at
//  launch, looping for ever, with layers that come in as the player's combo
//  climbs. Off unless asked for, twice over — the mode has to be on and the
//  music switched on inside it.
//
//  The app ships no audio files and this does not change that. Every layer is
//  written into a float buffer by hand — kick, snare, hats, a wobble sub and a
//  growl — and handed to one `AVAudioPlayerNode` each, all started at a single
//  host time so they stay in phase for as long as the app is open. Layers are
//  mixed in and out by volume rather than started and stopped, which is what
//  keeps the loop seamless while the arrangement changes underneath it.
//
//  It is a joke, but it is a joke about tempo and not about hearing damage, so
//  a few things are deliberate and not up for tuning by feel:
//
//  * Nothing is allowed above about 6 kHz. Dubstep's signature is the wobble,
//    which lives under 2 kHz; the piercing part of the genre is the part that
//    hurts, and it is simply not synthesised here. Hats are low-passed noise,
//    not a crash.
//  * Every hit has a raised-cosine attack of at least two milliseconds, for
//    the same reason the card sounds do: an instant onset is a click, and a
//    click at the top of a loop is a click four hundred times a minute.
//  * The master is 0.30 and the mix is soft-clipped with tanh, so the sum of
//    five layers cannot spike when they all land on beat one together.
//  * Turning it off fades out rather than cutting, and the fade is what the
//    stop actually waits for.
//

import AVFoundation

enum BrainrotAudio {

    /// Off by default, like every other noise this app can make.
    static var isEnabled = false

    // MARK: Tempo
    //
    // 140 BPM, and two bars per loop. 44100 × 8 × 60 ÷ 140 is 151,200 exactly,
    // so the loop is a whole number of samples and joins itself without a gap
    // — the one number in this file that has to be exact rather than tasteful.
    static let bpm = 140.0
    static let beatsPerLoop = 8
    static var beatInterval: Double { 60 / bpm }
    static let sampleRate = 44_100.0
    static var loopFrames: Int { Int(sampleRate * beatInterval * Double(beatsPerLoop)) }

    /// The arrangement. Each layer is a full loop; `floor` is the combo at
    /// which it joins in, so the music escalates with the mode.
    enum Layer: Int, CaseIterable {
        case drums, bass, hats, growl, riser

        /// Combo needed before this layer is mixed in.
        var floor: Int {
            switch self {
            case .drums: return 0
            case .bass: return 2
            case .hats: return 4
            case .growl: return 6
            case .riser: return 9
            }
        }

        /// Where it sits in the mix once it is in.
        var level: Float {
            switch self {
            case .drums: return 0.90
            case .bass: return 0.85
            case .hats: return 0.42
            case .growl: return 0.60
            case .riser: return 0.35
            }
        }
    }

    private static let master: Float = 0.30

    // MARK: Transport

    private final class Rig {
        let engine = AVAudioEngine()
        var players: [Layer: AVAudioPlayerNode] = [:]
        var fade: Timer?
    }

    private static var rig: Rig?
    private static var wanted = false

    static var isPlaying: Bool { rig?.engine.isRunning ?? false }

    /// Starts the loop, or does nothing if it is already going. Building the
    /// buffers takes a few milliseconds and happens once per launch, the first
    /// time the music is ever switched on — an app that never turns it on never
    /// pays for it.
    static func start() {
        guard isEnabled else { return }
        wanted = true
        // Already up — or on its way down. A fade-out that has not finished yet
        // still owns a running engine, so the right move is to turn it back
        // round rather than to build a second one; the completion block below
        // checks `wanted` before it tears anything down. This is the window
        // being clicked away from and back to inside a third of a second.
        if rig != nil {
            fadeMaster(to: master, over: 0.25)
            return
        }
        let rig = Rig()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        for layer in Layer.allCases {
            guard let buffer = buffer(for: layer, format: format) else { continue }
            let player = AVAudioPlayerNode()
            rig.engine.attach(player)
            rig.engine.connect(player, to: rig.engine.mainMixerNode, format: format)
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            player.volume = 0
            rig.players[layer] = player
        }
        rig.engine.mainMixerNode.outputVolume = 0
        rig.engine.prepare()

        do {
            try rig.engine.start()
        } catch {
            // No output device, or one that refused the format. The mode is
            // perfectly playable in silence, so this is not worth a dialog.
            return
        }

        // One host time for every node, a fraction of a second out, so the
        // layers start on the same sample instead of a few milliseconds apart.
        let start = AVAudioTime(hostTime: mach_absolute_time()
                                    + AVAudioTime.hostTime(forSeconds: 0.15))
        for player in rig.players.values { player.play(at: start) }
        Self.rig = rig
        fadeMaster(to: master, over: 0.7)
    }

    /// Fades out and tears down. Safe to call when nothing is playing.
    static func stop() {
        wanted = false
        guard let rig else { return }
        fadeMaster(to: 0, over: 0.35) {
            // Asked to start again while fading out: leave everything standing.
            guard !Self.wanted else { return }
            rig.engine.stop()
            for player in rig.players.values { player.stop() }
            if Self.rig === rig { Self.rig = nil }
        }
    }

    /// The combo drives the arrangement: one more layer every few moves, and
    /// silence back down to the drums when the player stops to think.
    static func setIntensity(combo: Int) {
        guard let rig else { return }
        for (layer, player) in rig.players {
            let target = combo >= layer.floor ? layer.level : 0
            ramp(player, to: target)
        }
    }

    // MARK: Level changes
    //
    // Volume is stepped rather than assigned: a sustained sub jumping from 0 to
    // full in one buffer is a click, and clicks are the thing this file is most
    // careful about.

    private static var ramps: [ObjectIdentifier: Timer] = [:]

    private static func ramp(_ player: AVAudioPlayerNode, to target: Float) {
        let key = ObjectIdentifier(player)
        guard abs(player.volume - target) > 0.001 else { return }
        ramps[key]?.invalidate()
        let from = player.volume
        let steps = 10
        var step = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            step += 1
            let t = Float(step) / Float(steps)
            player.volume = from + (target - from) * t
            if step >= steps {
                timer.invalidate()
                ramps[key] = nil
            }
        }
        ramps[key] = timer
    }

    private static func fadeMaster(to target: Float, over duration: Double,
                                   then finish: (() -> Void)? = nil) {
        guard let rig else { finish?(); return }
        rig.fade?.invalidate()
        let mixer = rig.engine.mainMixerNode
        let from = mixer.outputVolume
        let steps = max(1, Int(duration / 0.02))
        var step = 0
        rig.fade = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            step += 1
            mixer.outputVolume = from + (target - from) * Float(step) / Float(steps)
            if step >= steps {
                timer.invalidate()
                finish?()
            }
        }
    }

    // MARK: Synthesis

    private static var cache: [Layer: [Float]] = [:]

    private static func buffer(for layer: Layer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let samples = renderLayer(layer)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        for i in 0..<samples.count { channel[i] = samples[i] }
        return buffer
    }

    /// One layer's loop. Cached, because the buffers are also what `--sounds`
    /// exports and what the self-test measures.
    static func renderLayer(_ layer: Layer) -> [Float] {
        if let cached = cache[layer] { return cached }
        let frames = loopFrames
        var out = [Double](repeating: 0, count: frames)
        switch layer {
        case .drums: renderDrums(into: &out)
        case .bass: renderBass(into: &out)
        case .hats: renderHats(into: &out)
        case .growl: renderGrowl(into: &out)
        case .riser: renderRiser(into: &out)
        }
        // The loop joins itself every 3.4 seconds, and a layer that is still
        // making noise at the last sample — the riser by design, the growl
        // because its gate opens at the end of the bar — steps straight back
        // to whatever it starts with. That step is a click, four hundred times
        // a minute. Three milliseconds of raised cosine at each end is below
        // the threshold of a gap and above the threshold of an edge.
        taper(&out, seconds: 0.003)

        // Soft clip: tanh rounds the peaks off instead of squaring them, so a
        // layer that overshoots gets warmer rather than crunchier.
        let samples = out.map { Float(tanh($0)) }
        cache[layer] = samples
        return samples
    }

    /// The mix, at full intensity — every layer at the level it plays at.
    static func renderMix() -> [Float] {
        var out = [Float](repeating: 0, count: loopFrames)
        for layer in Layer.allCases {
            let samples = renderLayer(layer)
            for i in 0..<min(out.count, samples.count) {
                out[i] += samples[i] * layer.level * master
            }
        }
        return out.map { Float(tanh(Double($0))) }
    }

    private static func taper(_ out: inout [Double], seconds: Double) {
        let ramp = min(Int(seconds * sampleRate), out.count / 2)
        guard ramp > 1 else { return }
        for i in 0..<ramp {
            let gain = 0.5 - 0.5 * cos(.pi * Double(i) / Double(ramp - 1))
            out[i] *= gain
            out[out.count - 1 - i] *= gain
        }
    }

    private static func frame(ofBeat beat: Double) -> Int {
        Int(beat * beatInterval * sampleRate)
    }

    /// Half-time, which is the whole feel of the genre: the kick lands on the
    /// first beat of the bar and the snare waits all the way until the third,
    /// leaving a hole in the middle for the bass to move in.
    private static func renderDrums(into out: inout [Double]) {
        for bar in 0..<2 {
            let base = Double(bar * 4)
            kick(at: frame(ofBeat: base), into: &out)
            kick(at: frame(ofBeat: base + 3.5), into: &out, level: 0.45)
            snare(at: frame(ofBeat: base + 2), into: &out)
            if bar == 1 { snare(at: frame(ofBeat: base + 3.75), into: &out, level: 0.5) }
        }
    }

    /// A sine that falls from 110 Hz to 45 Hz as it decays: the classic, and
    /// the reason a dubstep kick is felt rather than heard.
    private static func kick(at offset: Int, into out: inout [Double], level: Double = 1.0) {
        let length = Int(0.34 * sampleRate)
        var phase = 0.0
        for i in 0..<length {
            let index = offset + i
            guard index < out.count else { break }
            let t = Double(i) / sampleRate
            let frequency = 45 + 65 * exp(-26 * t)
            phase += 2 * .pi * frequency / sampleRate
            let attack = min(1.0, t / 0.002)            // 2 ms, no click
            let body = exp(-7.5 * t) * attack
            out[index] += sin(phase) * body * 0.95 * level
        }
    }

    /// Mid-band noise over a short tone. Band-limited on purpose: the crack of
    /// a real snare lives where this file refuses to go.
    private static func snare(at offset: Int, into out: inout [Double], level: Double = 1.0) {
        let length = Int(0.22 * sampleRate)
        var rng = DeterministicRNG(seed: 0x5EED &+ UInt64(offset))
        var fast = 0.0, fast2 = 0.0, slow = 0.0
        for i in 0..<length {
            let index = offset + i
            guard index < out.count else { break }
            let t = Double(i) / sampleRate
            let white = Double(rng.next() >> 11) / Double(1 << 52) - 1.0
            // Two poles, not one. A single one-pole falls at 6 dB an octave,
            // which still leaves a measurable tail at 15 kHz; cascading it
            // doubles the slope and puts the top of the band where the comment
            // at the top of this file says it is.
            fast += 0.22 * (white - fast)
            fast2 += 0.22 * (fast - fast2)
            slow += 0.02 * (white - slow)
            let attack = min(1.0, t / 0.003)
            let envelope = exp(-16 * t) * attack
            let tone = sin(2 * .pi * 190 * t) * exp(-26 * t)
            out[index] += ((fast2 - slow) * 2.6 + tone * 0.5) * envelope * 0.75 * level
        }
    }

    /// Eighth notes, alternating hard and soft, each one a low-passed tick.
    private static func renderHats(into out: inout [Double]) {
        for step in 0..<(beatsPerLoop * 2) {
            let offset = frame(ofBeat: Double(step) * 0.5)
            let level = step % 2 == 0 ? 0.5 : 0.85       // the off-beat is the loud one
            let length = Int(0.05 * sampleRate)
            var rng = DeterministicRNG(seed: 0xA75_1CE &+ UInt64(step))
            var fast = 0.0, fast2 = 0.0, slow = 0.0
            for i in 0..<length {
                let index = offset + i
                guard index < out.count else { break }
                let t = Double(i) / sampleRate
                let white = Double(rng.next() >> 11) / Double(1 << 52) - 1.0
                fast += 0.30 * (white - fast)
                fast2 += 0.30 * (fast - fast2)
                slow += 0.06 * (white - slow)
                let position = Double(i) / Double(length - 1)
                let envelope = (0.5 - 0.5 * cos(2 * .pi * position)) * exp(-40 * t)
                out[index] += (fast2 - slow) * envelope * level * 3.4
            }
        }
    }

    /// The wobble. A sub sine, and an LFO opening and closing a one-pole filter
    /// on top of it — amplitude *and* brightness moving together is what makes
    /// it talk rather than just pulse. The LFO doubles in speed for the second
    /// bar, which is the entire arrangement.
    private static func renderBass(into out: inout [Double]) {
        // A1, A1, C2, G1: a minor shape, low enough to stay out of the growl.
        let notes: [(beat: Double, length: Double, frequency: Double)] = [
            (0, 2, 55.00), (2, 1.5, 55.00), (3.5, 0.5, 65.41),
            (4, 2, 48.99), (6, 1.5, 55.00), (7.5, 0.5, 73.42),
        ]
        var filtered = 0.0
        for note in notes {
            let offset = frame(ofBeat: note.beat)
            let length = frame(ofBeat: note.length)
            let wobbleRate = note.beat < 4 ? 2.0 / beatInterval : 4.0 / beatInterval
            var phase = 0.0
            for i in 0..<length {
                let index = offset + i
                guard index < out.count else { break }
                let t = Double(i) / sampleRate
                phase += 2 * .pi * note.frequency / sampleRate
                // Square-ish sub: a sine plus its own third harmonic, which
                // gives the filter something to chew on without adding fizz.
                let raw = sin(phase) + 0.35 * sin(3 * phase)
                let lfo = 0.5 - 0.5 * cos(2 * .pi * wobbleRate * t)
                let cutoff = 0.02 + 0.16 * lfo
                filtered += cutoff * (raw - filtered)
                let attack = min(1.0, t / 0.006)
                let release = min(1.0, (Double(length - i) / sampleRate) / 0.02)
                out[index] += filtered * (0.35 + 0.65 * lfo) * attack * release * 1.15
            }
        }
    }

    /// The growl on top: two detuned saws through the same kind of moving
    /// filter, an octave up from the sub. Kept under a low ceiling — this is
    /// the layer that would hurt if it were allowed to scream.
    private static func renderGrowl(into out: inout [Double]) {
        let frames = out.count
        var a = 0.0, b = 0.0, filtered = 0.0
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let beat = t / beatInterval
            // Rests in the first half of each bar, so it answers the kick
            // instead of covering it.
            let gate = (beat.truncatingRemainder(dividingBy: 4)) > 1.5 ? 1.0 : 0.0
            guard gate > 0 else { a = 0; b = 0; continue }

            // An octave above the sub. Down with the bass it was inaudible on
            // anything without a woofer — measured at two tenths of a percent
            // of the mix — and the wobble is the one thing this genre is for.
            let root = beat < 4 ? 220.0 : 196.0
            a += root / sampleRate
            b += (root * 1.008) / sampleRate            // detune, for the beating
            if a > 1 { a -= 1 }
            if b > 1 { b -= 1 }
            let saw = (a * 2 - 1) * 0.5 + (b * 2 - 1) * 0.5

            let lfo = 0.5 - 0.5 * cos(2 * .pi * (6 / beatInterval) * t)
            let cutoff = 0.015 + 0.085 * lfo            // ceiling well under 2 kHz
            filtered += cutoff * (saw - filtered)
            out[i] += filtered * (0.25 + 0.75 * lfo) * 2.6
        }
    }

    /// One bar of noise climbing to the top of the loop, so the join lands
    /// like something rather than coming round again.
    private static func renderRiser(into out: inout [Double]) {
        let start = frame(ofBeat: 6)
        var rng = DeterministicRNG(seed: 0x21_5E)
        var fast = 0.0, slow = 0.0
        for index in start..<out.count {
            let position = Double(index - start) / Double(out.count - start)
            let white = Double(rng.next() >> 11) / Double(1 << 52) - 1.0
            // The band walks upward as the bar goes on, but the top of the
            // sweep is still nowhere near a hiss.
            fast += (0.05 + 0.16 * position) * (white - fast)
            slow += (0.01 + 0.03 * position) * (white - slow)
            out[index] += (fast - slow) * position * position * 2.4
        }
    }

    /// Writes the loop out so it can be listened to without playing a game.
    /// Part of `Solitaire --sounds <directory>`.
    static func exportLoop(to directory: String) throws {
        let base = URL(fileURLWithPath: directory)
        let mix = base.appendingPathComponent("brainrot-loop.wav")
        try wav(renderMix()).write(to: mix)
        print("wrote \(mix.path)")
        // And every layer on its own, which is the only way to tell whether a
        // part that cannot be heard in the mix is quiet or broken.
        for layer in Layer.allCases {
            let url = base.appendingPathComponent("brainrot-\(layer).wav")
            try wav(renderLayer(layer)).write(to: url)
            print("wrote \(url.path)")
        }
    }

    private static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32_000) }
        let byteCount = pcm.count * 2
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        for sample in pcm { append(sample) }
        return data
    }
}
