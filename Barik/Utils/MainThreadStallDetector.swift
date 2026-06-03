import Foundation
import os

/// Detects main-thread stalls (the "icon visible but app frozen" zombie state).
///
/// Posts a lightweight heartbeat to the main queue every 2 seconds and verifies
/// from a background queue that the heartbeat fires within 5 seconds. If it
/// doesn't, the main runloop is wedged — log a `.fault` so the incident is
/// visible in Console.app for diagnosis.
///
/// This is observability, not recovery. It does not unwedge the app, but having
/// the log makes it possible to correlate stalls with their cause (e.g. a
/// runaway subprocess or a slow EventKit query) after the fact.
final class MainThreadStallDetector {
    static let shared = MainThreadStallDetector()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.barik",
        category: "StallDetector")
    private let probeInterval: TimeInterval = 2.0
    private let stallThreshold: TimeInterval = 5.0
    private let queue = DispatchQueue(label: "app.barik.stallDetector")
    private var timer: DispatchSourceTimer?
    private var lastHeartbeat: Date = Date()
    private var hasReportedCurrentStall = false
    private let lock = NSLock()

    private init() {}

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.timer != nil { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(
                deadline: .now() + self.probeInterval,
                repeating: self.probeInterval)
            t.setEventHandler { [weak self] in
                self?.tick()
            }
            t.resume()
            self.timer = t
            self.lastHeartbeat = Date()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func tick() {
        // Probe main with a tiny block that updates `lastHeartbeat`.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.lastHeartbeat = Date()
            let wasStalled = self.hasReportedCurrentStall
            self.hasReportedCurrentStall = false
            self.lock.unlock()
            if wasStalled {
                self.logger.notice("Main thread recovered from stall")
            }
        }
        // Check from background whether the previous heartbeat is overdue.
        lock.lock()
        let elapsed = Date().timeIntervalSince(lastHeartbeat)
        let alreadyReported = hasReportedCurrentStall
        if elapsed > stallThreshold {
            hasReportedCurrentStall = true
        }
        lock.unlock()
        if elapsed > stallThreshold && !alreadyReported {
            logger.fault(
                "Main thread stalled for \(elapsed, privacy: .public)s — UI is frozen. See subsystem app.barik in Console.app for upstream cause.")
        }
    }
}
