//
//  TableScheduler.swift
//  "Do this in a moment" for a card table: deal sequences, a bot's pause for
//  thought, the beat before a banner — every one cancellable at once.
//
//  A card game is full of little delays, and the bug they all breed is the
//  same: the player starts a new game, or walks away to the library, and a
//  block scheduled for the old hand fires into the new one. So nothing on a
//  table should use `asyncAfter` directly. Schedule through this, and
//  `cancelAll()` on a new game throws every pending step of the old one away.
//
//  It also keeps the energy rules. `suspend()` in `gameWillResignActive()`
//  stops every pending step without losing it — no wake-ups while the table
//  is out of sight — and `resume()` in `gameDidBecomeActive()` carries on
//  with the time each one had left.
//
//  And it makes sequences testable and photographable. In immediate mode
//  (on by default while `--shot` runs) nothing waits: blocks run in the order
//  they would have, on a virtual clock, the moment they are scheduled — a
//  whole deal lands synchronously and a screenshot sees the settled table.
//  `runPendingImmediately()` does the same on demand for a self-test.
//

import AppKit

@MainActor
final class TableScheduler {

    /// Identifies one scheduled block, for cancelling just that one.
    struct Token: Hashable {
        fileprivate let id: Int
    }

    private struct Entry {
        let id: Int
        /// When it is due: `CACurrentMediaTime()` time in live mode, virtual
        /// time in immediate mode.
        var due: TimeInterval
        let block: () -> Void
        var work: DispatchWorkItem?
    }

    /// Run blocks at once, in due order, instead of waiting. Defaults to on
    /// while a snapshot is being rendered.
    var isImmediate: Bool

    /// True between `suspend()` and `resume()`.
    private(set) var isSuspended = false

    private var entries: [Entry] = []
    private var nextID = 0
    private var virtualNow: TimeInterval = 0
    private var draining = false
    /// Remaining time of each entry, while suspended.
    private var remaining: [Int: TimeInterval] = [:]

    init(immediate: Bool = TabletopEnvironment.isRenderingSnapshot) {
        isImmediate = immediate
    }

    /// Blocks waiting to run.
    var pendingCount: Int { entries.count }

    /// Runs `block` after `delay` seconds — unless it is cancelled first, or
    /// the scheduler is suspended when the time comes (then it runs that
    /// much later, after `resume()`).
    @discardableResult
    func after(_ delay: TimeInterval, _ block: @escaping () -> Void) -> Token {
        nextID += 1
        let id = nextID
        if isImmediate {
            entries.append(Entry(id: id, due: virtualNow + max(0, delay), block: block, work: nil))
            drain()
            return Token(id: id)
        }
        var entry = Entry(id: id, due: CACurrentMediaTime() + max(0, delay), block: block, work: nil)
        if isSuspended {
            remaining[id] = max(0, delay)
        } else {
            entry.work = dispatch(id, after: max(0, delay))
        }
        entries.append(entry)
        return Token(id: id)
    }

    /// Cancels one block. Harmless if it already ran.
    func cancel(_ token: Token) {
        guard let index = entries.firstIndex(where: { $0.id == token.id }) else { return }
        entries[index].work?.cancel()
        entries.remove(at: index)
        remaining[token.id] = nil
    }

    /// Cancels everything pending. Call it when a new hand or game starts.
    func cancelAll() {
        for entry in entries { entry.work?.cancel() }
        entries.removeAll()
        remaining.removeAll()
    }

    /// Holds every pending block where it is. The table has gone out of
    /// sight; nothing should wake the processor for it.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        let now = CACurrentMediaTime()
        for i in entries.indices {
            entries[i].work?.cancel()
            entries[i].work = nil
            remaining[entries[i].id] = max(0, entries[i].due - now)
        }
    }

    /// Carries on after `suspend()`, each block with the time it had left.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        let now = CACurrentMediaTime()
        for i in entries.indices {
            let left = remaining[entries[i].id] ?? 0
            entries[i].due = now + left
            entries[i].work = dispatch(entries[i].id, after: left)
        }
        remaining.removeAll()
    }

    /// Runs every pending block now, in the order they were due — including
    /// any that those blocks schedule, on a virtual clock — until nothing is
    /// left. For a test, or a screenshot of a sequence already under way.
    func runPendingImmediately() {
        for i in entries.indices { entries[i].work?.cancel(); entries[i].work = nil }
        let wasImmediate = isImmediate
        // Rebase the pending entries onto the virtual clock, keeping their
        // order and spacing.
        let now = CACurrentMediaTime()
        virtualNow = 0
        for i in entries.indices {
            entries[i].due = isSuspended ? (remaining[entries[i].id] ?? 0) : max(0, entries[i].due - now)
        }
        remaining.removeAll()
        isImmediate = true
        drain()
        isImmediate = wasImmediate
        virtualNow = 0
    }

    // MARK: Plumbing

    private func dispatch(_ id: Int, after delay: TimeInterval) -> DispatchWorkItem {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fire(id) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }

    private func fire(_ id: Int) {
        guard !isSuspended, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        entry.block()
    }

    /// Immediate mode: pop the earliest entry (first scheduled wins a tie),
    /// move the virtual clock to it, run it, repeat.
    private func drain() {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while let index = entries.indices.min(by: {
            (entries[$0].due, entries[$0].id) < (entries[$1].due, entries[$1].id)
        }) {
            let entry = entries.remove(at: index)
            virtualNow = max(virtualNow, entry.due)
            entry.block()
        }
    }
}
