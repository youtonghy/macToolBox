import AppKit
import Combine
import CoreGraphics
import Foundation
import OSLog

enum BrightnessScheduleRuntimeState: Equatable, Sendable {
    case disabled
    case waitingForDisplays
    case active(
        brightnessPercent: Int,
        displayCount: Int,
        nextTransition: Date?,
        overrideCount: Int
    )
}

private struct ManualBrightnessOverride: Equatable {
    var displayID: CGDirectDisplayID
    var normalizedValue: Double
    var segmentID: UUID
    var expiresAt: Date
}

private struct DisplayTopologySignature: Hashable {
    var displayID: CGDirectDisplayID
    var vendorNumber: UInt32?
    var modelNumber: UInt32?
    var serialNumber: UInt32?
    var brightnessWritable: Bool
    var rawMinimum: UInt16?
    var rawMaximum: UInt16?
    /// Included so a same-ID replug (new registry connection) is treated as
    /// a topology change even when every other field matches.
    var connectionToken: UInt64?
}

/// Applies a validated brightness schedule to all controllable external displays.
@MainActor
final class BrightnessScheduleCoordinator: ObservableObject {
    @Published private(set) var configuration: BrightnessScheduleConfiguration
    @Published private(set) var runtimeState: BrightnessScheduleRuntimeState = .disabled
    @Published private(set) var configurationIssue: BrightnessScheduleConfigurationIssue?

    private let service: DisplayControlService
    private let store: BrightnessScheduleStore
    private let clock: BrightnessScheduleClock
    private let retryClock: BrightnessScheduleClock
    private let observesSystemEvents: Bool
    private let logger = Logger(subsystem: "ToolBox", category: "BrightnessSchedule")

    private var cancellables = Set<AnyCancellable>()
    private var notificationObservers: [NSObjectProtocol] = []
    private var wantsRunning = false
    private var timerGeneration: UInt64 = 0
    private var overrides: [CGDirectDisplayID: ManualBrightnessOverride] = [:]
    private var lastSignatures: [CGDirectDisplayID: DisplayTopologySignature] = [:]
    private var isSleepSuspended = false
    private var awaitingPostWakeSnapshot = false
    private var wakeFallbackWorkItem: DispatchWorkItem?

    private struct ScheduledWriteRetry {
        var attempts: Int
        /// Earliest time the display may be rewritten. `.distantFuture` marks
        /// an exhausted budget: the display stays deferred until a full
        /// schedule trigger resets it.
        var dueAt: Date
    }

    private var scheduledWriteRetries: [CGDirectDisplayID: ScheduledWriteRetry] = [:]
    private var retryFireDate: Date?
    private var retryGeneration: UInt64 = 0
    private var lastActiveSegmentID: UUID?
    /// Connection tokens recorded when overrides were last pruned; a changed
    /// token under the same ID means the display was replugged and its
    /// manual override must not carry over.
    private var overrideConnectionTokens: [CGDirectDisplayID: UInt64?] = [:]
    /// Increments on stop(); stale notification callbacks and delayed wake
    /// closures from a previous session are dropped by comparing against it.
    private var lifecycleGeneration: UInt64 = 0
    /// Identifies the current wake cycle so an older cycle's delayed settle
    /// closure cannot end a newer one early.
    private var wakeCycleID = UUID()
    /// Monotonic timestamp of the last wake settle. Paired wake notifications
    /// (screensDidWake + didWake) that arrive after a completed settle must
    /// not start a second refresh/rewrite cycle.
    private var lastWakeSettleUptimeNanos: UInt64 = 0

    /// Exponential backoff for failed scheduled writes; after the last step
    /// the display gives up until the next schedule trigger.
    static let retryDelays: [TimeInterval] = [2, 8, 30, 120, 300]

    init(
        service: DisplayControlService,
        store: BrightnessScheduleStore = BrightnessScheduleStore(),
        clock: BrightnessScheduleClock = FoundationBrightnessScheduleClock(),
        retryClock: BrightnessScheduleClock = FoundationBrightnessScheduleClock(),
        observesSystemEvents: Bool = true
    ) {
        self.service = service
        self.store = store
        self.clock = clock
        self.retryClock = retryClock
        self.observesSystemEvents = observesSystemEvents
        let loaded = store.load()
        configuration = loaded.configuration
        configurationIssue = loaded.issue
    }

    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        // Defensive: a stale sleep/wake callback from a previous session must
        // not leave the new session suspended.
        isSleepSuspended = false
        awaitingPostWakeSnapshot = false
        wakeFallbackWorkItem?.cancel()
        wakeFallbackWorkItem = nil

        // Already @MainActor; avoid receive(on:) which can stall unit tests waiting on async workers.
        service.$snapshot
            .sink { [weak self] snapshot in
                self?.handleSnapshot(snapshot)
            }
            .store(in: &cancellables)

        service.manualBrightnessWrites
            .sink { [weak self] event in
                self?.handleManualWrite(displayID: event.displayID, normalizedValue: event.normalizedValue)
            }
            .store(in: &cancellables)

        service.brightnessWriteFailures
            .sink { [weak self] event in
                self?.handleScheduledWriteFailure(displayID: event.displayID, policy: event.policy)
            }
            .store(in: &cancellables)

        if observesSystemEvents {
            registerNotifications()
        }
        reconcile(reason: .start)
    }

    func stop() {
        wantsRunning = false
        cancellables.removeAll()
        unregisterNotifications()
        wakeFallbackWorkItem?.cancel()
        wakeFallbackWorkItem = nil
        clock.cancel()
        retryClock.cancel()
        timerGeneration += 1
        retryGeneration += 1
        lifecycleGeneration += 1
        retryFireDate = nil
        scheduledWriteRetries.removeAll()
        lastActiveSegmentID = nil
        overrideConnectionTokens.removeAll()
        overrides.removeAll()
        lastSignatures.removeAll()
        isSleepSuspended = false
        awaitingPostWakeSnapshot = false
        runtimeState = .disabled
    }

    func commit(_ configuration: BrightnessScheduleConfiguration) throws {
        try store.save(configuration)
        self.configuration = configuration
        configurationIssue = nil
        overrides.removeAll()
        reconcile(reason: .commit)
    }

    // MARK: - Reconciliation

    private enum ReconcileReason {
        case start
        case commit
        case timer
        case snapshot
        case retry
        case wake
        case clockChange
        case sleep
    }

    /// Reconciles against the given snapshot. Callers that react to a
    /// @Published emission MUST pass the emitted value: during the sink
    /// callback `service.snapshot` still holds the previous snapshot
    /// (@Published emits on willSet).
    private func reconcile(reason: ReconcileReason, snapshot publishedSnapshot: DisplayControlSnapshot? = nil) {
        let snapshot = publishedSnapshot ?? service.snapshot
        guard wantsRunning else { return }

        if reason == .sleep {
            clock.cancel()
            timerGeneration += 1
            retryClock.cancel()
            retryGeneration += 1
            retryFireDate = nil
            scheduledWriteRetries.removeAll()
            return
        }

        if isSleepSuspended, reason != .wake {
            return
        }

        guard configuration.isEnabled else {
            clock.cancel()
            timerGeneration += 1
            retryClock.cancel()
            retryGeneration += 1
            retryFireDate = nil
            scheduledWriteRetries.removeAll()
            overrides.removeAll()
            lastSignatures = signatures(from: service.snapshot)
            runtimeState = .disabled
            return
        }

        let now = clock.now
        let calendar = clock.calendar
        guard let match = configuration.schedule.match(at: now, calendar: calendar) else {
            runtimeState = .waitingForDisplays
            return
        }

        // PLAN trigger matrix: a clock/zone change rewrites everything only
        // when the active segment actually moved; otherwise it just
        // reschedules the timer and recalculates override expiry.
        let activeSegmentChanged = lastActiveSegmentID != match.activeSegment.id
        lastActiveSegmentID = match.activeSegment.id

        // PLAN: on clock/zone changes, recalculate expiry for still-valid
        // same-segment overrides so they track the recomputed boundary.
        if reason == .clockChange {
            for (displayID, override) in overrides where override.segmentID == match.activeSegment.id {
                overrides[displayID] = ManualBrightnessOverride(
                    displayID: override.displayID,
                    normalizedValue: override.normalizedValue,
                    segmentID: override.segmentID,
                    expiresAt: match.nextTransition
                )
            }
        }

        expireOverrides(activeSegmentID: match.activeSegment.id, now: now)

        let eligible = eligibleDisplays(in: snapshot)
        let signatures = signatures(from: snapshot)
        var writeTargets = displaysToWrite(
            reason: reason,
            eligible: eligible,
            signatures: signatures,
            activeSegmentChanged: activeSegmentChanged
        )

        // A display with a pending retry must not be rewritten by an
        // ordinary snapshot refresh before its backoff elapses — otherwise
        // the post-failure refresh burns the whole budget in one burst.
        var deferredRetryDisplayIDs = Set<CGDirectDisplayID>()
        if reason == .snapshot || reason == .retry {
            for display in writeTargets where isRetryDeferred(display.id, now: now) {
                deferredRetryDisplayIDs.insert(display.id)
            }
            if !deferredRetryDisplayIDs.isEmpty {
                writeTargets.removeAll { deferredRetryDisplayIDs.contains($0.id) }
            }
        }

        // A fresh write from a full-scope trigger restarts the retry budget;
        // retry- and snapshot-driven writes must not (they would reset the
        // budget on every failed attempt and loop forever). A clock change
        // only counts as a full trigger when the active segment moved.
        let resetsRetryBudget: Bool
        switch reason {
        case .start, .commit, .timer, .wake:
            resetsRetryBudget = true
        case .clockChange:
            resetsRetryBudget = activeSegmentChanged
        case .snapshot, .retry, .sleep:
            resetsRetryBudget = false
        }

        for display in writeTargets {
            if resetsRetryBudget {
                scheduledWriteRetries[display.id] = nil
            }
            let value = effectiveNormalizedValue(
                for: display.id,
                scheduled: match.activeSegment.normalizedBrightness
            )
            service.writeBrightness(
                displayID: display.id,
                normalizedValue: value,
                smooth: false,
                policy: .scheduled
            )
        }

        lastSignatures = signatures
        // Deferred displays keep their signature cleared so the retry timer
        // still finds them pending when their backoff elapses.
        for displayID in deferredRetryDisplayIDs {
            lastSignatures[displayID] = nil
        }

        if eligible.isEmpty {
            runtimeState = .waitingForDisplays
        } else {
            runtimeState = .active(
                brightnessPercent: match.activeSegment.brightnessPercent,
                displayCount: eligible.count,
                nextTransition: match.nextTransition,
                overrideCount: overrides.count
            )
        }

        scheduleNextTimer(match: match, now: now)
    }

    private func displaysToWrite(
        reason: ReconcileReason,
        eligible: [DisplayControlDisplay],
        signatures: [CGDirectDisplayID: DisplayTopologySignature],
        activeSegmentChanged: Bool
    ) -> [DisplayControlDisplay] {
        switch reason {
        case .start, .commit, .timer, .wake:
            return eligible
        case .clockChange:
            // Within the same segment a clock change only reschedules; a
            // segment move behaves like a boundary crossing and rewrites.
            guard activeSegmentChanged else {
                return []
            }
            return eligible
        case .snapshot, .retry:
            return eligible.filter { display in
                let signature = signatures[display.id]
                let previous = lastSignatures[display.id]
                return previous != signature
            }
        case .sleep:
            return []
        }
    }

    private func effectiveNormalizedValue(
        for displayID: CGDirectDisplayID,
        scheduled: Double
    ) -> Double {
        if let override = overrides[displayID] {
            return override.normalizedValue
        }
        return scheduled
    }

    private func expireOverrides(activeSegmentID: UUID, now: Date) {
        overrides = overrides.filter { _, override in
            override.segmentID == activeSegmentID && override.expiresAt > now
        }
    }

    private func handleManualWrite(displayID: CGDirectDisplayID, normalizedValue: Double) {
        guard wantsRunning, configuration.isEnabled else { return }
        guard eligibleDisplays(in: service.snapshot).contains(where: { $0.id == displayID }) else {
            return
        }
        let now = clock.now
        guard let match = configuration.schedule.match(at: now, calendar: clock.calendar) else {
            return
        }
        overrides[displayID] = ManualBrightnessOverride(
            displayID: displayID,
            normalizedValue: normalizedValue,
            segmentID: match.activeSegment.id,
            expiresAt: match.nextTransition
        )
        if case let .active(percent, count, next, _) = runtimeState {
            runtimeState = .active(
                brightnessPercent: percent,
                displayCount: count,
                nextTransition: next,
                overrideCount: overrides.count
            )
        }
    }

    private func handleSnapshot(_ snapshot: DisplayControlSnapshot) {
        if awaitingPostWakeSnapshot {
            // Settle on the first non-empty post-wake snapshot. Comparing
            // wall-clock timestamps would deadlock when the clock steps back
            // (NTP resync after wake); the 5s fallback force-settles when no
            // usable snapshot ever arrives.
            if !snapshot.displays.isEmpty {
                awaitingPostWakeSnapshot = false
                wakeFallbackWorkItem?.cancel()
                wakeFallbackWorkItem = nil
                isSleepSuspended = false
                lastWakeSettleUptimeNanos = DispatchTime.now().uptimeNanoseconds
                // The first settled snapshot is authoritative for display
                // presence; discard overrides for displays that did not
                // return or were replugged under the same ID.
                pruneOverrides(liveDisplays: snapshot.displays)
                reconcile(reason: .wake, snapshot: snapshot)
            }
            return
        }

        // During sleep, CoreGraphics can publish an empty/intermediate topology.
        // Keep overrides until the first settled post-wake snapshot so that the
        // effective value is restored instead of falling back to the schedule.
        if !isSleepSuspended {
            // Defensive: an empty snapshot combined with a refresh error means
            // the probe failed, not that all displays vanished.
            if snapshot.displays.isEmpty, service.lastRefreshError != nil {
                return
            }
            pruneOverrides(liveDisplays: snapshot.displays)
        }
        reconcile(reason: .snapshot, snapshot: snapshot)
    }

    /// Removes overrides and retry state for absent displays and for
    /// replugged displays (same CGDirectDisplayID, different connection
    /// token), then records the current tokens. PLAN: a replugged display
    /// gets the current schedule value, never a stale manual override or a
    /// stale retry deferral (including budget exhaustion).
    private func pruneOverrides(liveDisplays: [DisplayControlDisplay]) {
        let liveIDs = Set(liveDisplays.map(\.id))
        overrides = overrides.filter { liveIDs.contains($0.key) }
        for display in liveDisplays {
            let token = display.connectionToken
            if let previous = overrideConnectionTokens[display.id], previous != token {
                overrides.removeValue(forKey: display.id)
                scheduledWriteRetries.removeValue(forKey: display.id)
            }
            overrideConnectionTokens[display.id] = token
        }
        for displayID in overrideConnectionTokens.keys where !liveIDs.contains(displayID) {
            overrideConnectionTokens.removeValue(forKey: displayID)
            scheduledWriteRetries.removeValue(forKey: displayID)
        }
        if scheduledWriteRetries.isEmpty {
            retryClock.cancel()
            retryGeneration += 1
            retryFireDate = nil
        }
    }

    // MARK: - Scheduled write failure retry

    private func handleScheduledWriteFailure(displayID: CGDirectDisplayID, policy: DisplayBrightnessWritePolicy) {
        guard wantsRunning, configuration.isEnabled, policy == .scheduled else { return }

        var state = scheduledWriteRetries[displayID] ?? ScheduledWriteRetry(attempts: 0, dueAt: .distantPast)
        guard state.attempts < Self.retryDelays.count else {
            // Keep the display deferred forever (until a full trigger) so
            // neither the retry timer nor refresh-driven reconciles keep
            // hammering a dead connection.
            state.dueAt = .distantFuture
            scheduledWriteRetries[displayID] = state
            logger.error("Scheduled brightness retry budget exhausted for display \(displayID, privacy: .public); waiting for the next schedule trigger.")
            return
        }
        let delay = Self.retryDelays[state.attempts]
        state.attempts += 1
        state.dueAt = clock.now.addingTimeInterval(delay)
        scheduledWriteRetries[displayID] = state

        // Drop the recorded signature so the next reconcile rewrites this
        // display instead of skipping it as unchanged.
        lastSignatures[displayID] = nil
        scheduleRetryTimer(at: state.dueAt)
    }

    private func isRetryDeferred(_ displayID: CGDirectDisplayID, now: Date) -> Bool {
        guard let state = scheduledWriteRetries[displayID] else { return false }
        return state.dueAt > now
    }

    /// Schedules the retry clock for the earliest pending per-display due
    /// date, so every display retries on its own backoff.
    private func scheduleNextPendingRetry() {
        let now = clock.now
        let upcoming = scheduledWriteRetries.values
            .map(\.dueAt)
            .filter { $0 > now && $0 != .distantFuture }
        guard let next = upcoming.min() else { return }
        scheduleRetryTimer(at: next)
    }

    private func scheduleRetryTimer(at date: Date) {
        if let existing = retryFireDate, existing <= date { return }
        retryFireDate = date
        retryGeneration += 1
        let generation = retryGeneration
        retryClock.schedule(at: date, generation: generation) { [weak self] firedGeneration in
            Task { @MainActor in
                guard let self, self.retryGeneration == firedGeneration else { return }
                self.retryFireDate = nil
                self.reconcile(reason: .retry)
                // Other displays may still be waiting on their own backoff.
                self.scheduleNextPendingRetry()
            }
        }
    }

    // MARK: - Timer

    private func scheduleNextTimer(match: BrightnessScheduleMatch, now: Date) {
        timerGeneration += 1
        let generation = timerGeneration
        var fireDate = match.nextTransition
        var firesAtDSTTransition = false

        if let dst = clock.calendar.timeZone.nextDaylightSavingTimeTransition(after: now),
           dst < fireDate {
            fireDate = dst
            firesAtDSTTransition = true
        }

        clock.schedule(at: fireDate, generation: generation) { [weak self] firedGeneration in
            Task { @MainActor in
                guard let self else { return }
                guard self.timerGeneration == firedGeneration else { return }
                // A DST-only fire within the same segment reschedules the
                // timer and recalculates override expiry (like a clock
                // change) instead of rewriting every display.
                self.reconcile(reason: firesAtDSTTransition ? .clockChange : .timer)
            }
        }
    }

    // MARK: - Targets

    private func eligibleDisplays(in snapshot: DisplayControlSnapshot) -> [DisplayControlDisplay] {
        snapshot.displays.filter { display in
            guard !display.isBuiltIn, !display.isVirtual, display.supportsHardwareDDC else {
                return false
            }
            return display.controls.contains {
                $0.kind == .brightness && $0.status.isWritable
            }
        }
    }

    private func signatures(
        from snapshot: DisplayControlSnapshot
    ) -> [CGDirectDisplayID: DisplayTopologySignature] {
        var result: [CGDirectDisplayID: DisplayTopologySignature] = [:]
        for display in snapshot.displays {
            let brightness = display.controls.first(where: { $0.kind == .brightness })
            result[display.id] = DisplayTopologySignature(
                displayID: display.id,
                vendorNumber: display.vendorNumber,
                modelNumber: display.modelNumber,
                serialNumber: display.serialNumber,
                brightnessWritable: brightness?.status.isWritable == true,
                rawMinimum: brightness?.value?.rawMinimum,
                rawMaximum: brightness?.value?.rawMaximum,
                connectionToken: display.connectionToken
            )
        }
        return result
    }

    // MARK: - Notifications

    private func registerNotifications() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        // Explicit .main delivery makes the synchronous MainActor hops below valid.
        let generation = lifecycleGeneration

        let sleepNames: [Notification.Name] = [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.willSleepNotification
        ]
        for name in sleepNames {
            notificationObservers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.handleSleep(generation: generation)
                    }
                }
            )
        }

        let wakeNames: [Notification.Name] = [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification
        ]
        for name in wakeNames {
            notificationObservers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.handleWake(generation: generation)
                    }
                }
            )
        }

        let clockNames: [Notification.Name] = [
            .NSSystemClockDidChange,
            .NSSystemTimeZoneDidChange,
            .NSCalendarDayChanged
        ]
        for name in clockNames {
            notificationObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        // Stale notifications queued before stop() must not
                        // touch a freshly started session.
                        guard let self,
                              self.wantsRunning,
                              self.lifecycleGeneration == generation else { return }
                        self.reconcile(reason: .clockChange)
                    }
                }
            )
        }
    }

    private func unregisterNotifications() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in notificationObservers {
            center.removeObserver(observer)
            workspace.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    private func handleSleep(generation: UInt64) {
        // Stale notifications queued before stop() must not suspend a
        // freshly started session.
        guard wantsRunning, lifecycleGeneration == generation else { return }
        isSleepSuspended = true
        awaitingPostWakeSnapshot = false
        lastWakeSettleUptimeNanos = 0
        wakeFallbackWorkItem?.cancel()
        wakeFallbackWorkItem = nil
        clock.cancel()
        timerGeneration += 1
        reconcile(reason: .sleep)
    }

    private func handleWake(generation: UInt64) {
        guard wantsRunning, lifecycleGeneration == generation else { return }
        // A paired duplicate wake (screensDidWake + didWake) arriving after
        // this cycle already settled must not start a second refresh and
        // full rewrite. A genuine new sleep clears the marker.
        if !awaitingPostWakeSnapshot,
           !isSleepSuspended,
           lastWakeSettleUptimeNanos > 0,
           DispatchTime.now().uptimeNanoseconds &- lastWakeSettleUptimeNanos < 10_000_000_000 {
            return
        }
        // Coalesce duplicate wake notifications; each new wake cycle
        // invalidates delayed closures from older cycles.
        let cycle = UUID()
        wakeCycleID = cycle
        awaitingPostWakeSnapshot = true
        isSleepSuspended = true
        clock.cancel()
        timerGeneration += 1

        wakeFallbackWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.wantsRunning,
                  self.lifecycleGeneration == generation,
                  self.wakeCycleID == cycle,
                  self.awaitingPostWakeSnapshot else { return }
            self.service.refresh()
            // If the refresh fails (no snapshot published) or reports an
            // empty erroring topology, force-settle so the coordinator never
            // remains suspended indefinitely.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self,
                      self.wantsRunning,
                      self.lifecycleGeneration == generation,
                      self.wakeCycleID == cycle,
                      self.awaitingPostWakeSnapshot else { return }
                self.awaitingPostWakeSnapshot = false
                self.isSleepSuspended = false
                self.lastWakeSettleUptimeNanos = DispatchTime.now().uptimeNanoseconds
                self.reconcile(reason: .wake)
            }
        }
        wakeFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}
