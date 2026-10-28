import EventKit
import Foundation
import Observation

/// Manages calendar event queries.
///
/// Event-driven via `EKEventStoreChanged` — EventKit posts that notification
/// whenever the store mutates (new event, sync from iCloud, etc.). A 5-minute
/// safety-net tick keeps the "next event" up to date even if no events fire
/// (e.g. when an event simply starts).
///
/// A single shared instance backs every time widget and calendar popup:
/// `EKEventStore` is expensive to create and previously a new manager (and
/// store) was built on every bar re-render.
@MainActor
@Observable
final class CalendarManager {
    static let shared = CalendarManager()

    private(set) var nextEvent: EKEvent?
    private(set) var todaysEvents: [EKEvent] = []
    private(set) var tomorrowsEvents: [EKEvent] = []

    @ObservationIgnored private let store = EventStoreBox()
    @ObservationIgnored private var allowList: [String] = []
    @ObservationIgnored private var denyList: [String] = []
    @ObservationIgnored private var isMonitoring = false
    @ObservationIgnored private var refreshInFlight = false
    @ObservationIgnored private var needsRefresh = false

    private init() {
        requestAccess()
    }

    /// Applies the widget's `calendar.allow-list` / `calendar.deny-list`.
    func updateConfig(_ config: ConfigData) {
        let calendar = config["calendar"]?.dictionaryValue
        func list(_ key: String) -> [String] {
            calendar?[key]?.arrayValue?.compactMap(\.stringValue)
                .filter { !$0.isEmpty } ?? []
        }
        let allow = list("allow-list")
        let deny = list("deny-list")
        guard allow != allowList || deny != denyList else { return }
        allowList = allow
        denyList = deny
        refresh()
    }

    private func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store.eventStore,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func requestAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            startMonitoring()
        case .notDetermined:
            Task {
                do {
                    guard try await store.eventStore.requestFullAccessToEvents()
                    else { return }
                    startMonitoring()
                } catch {
                    print("Calendar access not granted: \(error)")
                }
            }
        default:
            break
        }
    }

    /// Fetches today's and tomorrow's events off the main actor.
    private func refresh() {
        guard isMonitoring else { return }
        guard !refreshInFlight else {
            // Coalesce: run once more after the in-flight fetch finishes.
            needsRefresh = true
            return
        }
        refreshInFlight = true
        Task {
            let snapshot = await Self.fetch(
                from: store, allowList: allowList, denyList: denyList)
            todaysEvents = snapshot.today
            nextEvent = snapshot.next
            tomorrowsEvents = snapshot.tomorrow
            refreshInFlight = false
            if needsRefresh {
                needsRefresh = false
                refresh()
            }
        }
    }

    /// EventKit objects aren't `Sendable`, but the fetched events are freshly
    /// created and only handed over once, so moving them across is safe.
    nonisolated private struct Snapshot: @unchecked Sendable {
        var today: [EKEvent] = []
        var next: EKEvent?
        var tomorrow: [EKEvent] = []
    }

    @concurrent
    private nonisolated static func fetch(
        from store: EventStoreBox, allowList: [String], denyList: [String]
    ) async -> Snapshot {
        let eventStore = store.eventStore
        let calendars = eventStore.calendars(for: .event).filter {
            (allowList.isEmpty || allowList.contains($0.title))
                && !denyList.contains($0.title)
        }
        guard !calendars.isEmpty else { return Snapshot() }

        let now = Date()
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
        guard
            let startOfTomorrow = cal.date(
                byAdding: .day, value: 1, to: startOfDay),
            let endOfTomorrow = cal.date(
                byAdding: .day, value: 1, to: startOfTomorrow)
        else { return Snapshot() }

        func events(from start: Date, to end: Date) -> [EKEvent] {
            eventStore.events(
                matching: eventStore.predicateForEvents(
                    withStart: start, end: end, calendars: calendars)
            ).sorted { $0.startDate < $1.startDate }
        }

        let today = events(from: startOfDay, to: startOfTomorrow)
        // Still-running and future events; the "next" one may be in progress.
        let upcoming = today.filter { $0.endDate >= now }
        return Snapshot(
            today: upcoming,
            next: upcoming.first(where: { !$0.isAllDay }) ?? upcoming.first,
            tomorrow: events(from: startOfTomorrow, to: endOfTomorrow))
    }
}

/// `EKEventStore` is documented as safe to query from background threads.
nonisolated final class EventStoreBox: @unchecked Sendable {
    let eventStore = EKEventStore()
}
