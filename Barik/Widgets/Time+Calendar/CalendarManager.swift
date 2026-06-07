import EventKit
import Foundation

/// Manages calendar event queries.
///
/// Event-driven via `EKEventStoreChanged` — EventKit posts that notification
/// whenever the store mutates (new event, sync from iCloud, etc.). A 5-minute
/// safety-net timer keeps the "next event" up to date even if no events fire
/// (e.g. when an event simply starts).
class CalendarManager: ObservableObject {
    let configProvider: ConfigProvider
    var config: ConfigData? {
        configProvider.config["calendar"]?.dictionaryValue
    }
    var allowList: [String] {
        Array(
            (config?["allow-list"]?.arrayValue?.map { $0.stringValue ?? "" }
                .drop(while: { $0 == "" })) ?? [])
    }
    var denyList: [String] {
        Array(
            (config?["deny-list"]?.arrayValue?.map { $0.stringValue ?? "" }
                .drop(while: { $0 == "" })) ?? [])
    }

    @Published var nextEvent: EKEvent?
    @Published var todaysEvents: [EKEvent] = []
    @Published var tomorrowsEvents: [EKEvent] = []

    private let eventStore = EKEventStore()
    private var safetyTimer: Timer?
    private var refreshInFlight = false

    init(configProvider: ConfigProvider) {
        self.configProvider = configProvider
        requestAccess()
    }

    deinit {
        stopMonitoring()
        NotificationCenter.default.removeObserver(self)
    }

    private func startMonitoring() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventStoreChanged),
            name: .EKEventStoreChanged,
            object: eventStore)

        // 5-minute safety net catches "next event" transitions (events that just started/ended).
        safetyTimer = Timer.scheduledTimer(
            withTimeInterval: 300.0, repeats: true
        ) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    private func stopMonitoring() {
        safetyTimer?.invalidate()
        safetyTimer = nil
    }

    @objc private func eventStoreChanged() {
        refresh()
    }

    private func requestAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess:
            startMonitoring()
        case .notDetermined:
            eventStore.requestFullAccessToEvents { [weak self] granted, error in
                guard granted, error == nil else {
                    if let error {
                        print("Calendar access not granted: \(error)")
                    }
                    return
                }
                DispatchQueue.main.async {
                    self?.startMonitoring()
                }
            }
        default:
            break
        }
    }

    private func filterEvents(
        _ events: [EKEvent], allowList: [String], denyList: [String]
    ) -> [EKEvent] {
        var filtered = events
        if !allowList.isEmpty {
            filtered = filtered.filter { allowList.contains($0.calendar.title) }
        }
        if !denyList.isEmpty {
            filtered = filtered.filter { !denyList.contains($0.calendar.title) }
        }
        return filtered
    }

    /// Fetches today's and tomorrow's events on a background queue and republishes results on main.
    private func refresh() {
        assert(Thread.isMainThread)
        guard !refreshInFlight else { return }
        refreshInFlight = true

        // Capture config from main (it's a SwiftUI @Published-derived value).
        let allow = allowList
        let deny = denyList

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let calendars = self.eventStore.calendars(for: .event)
            let now = Date()
            let cal = Calendar.current
            let startOfDay = cal.startOfDay(for: now)
            guard
                let endOfDay = cal.date(
                    bySettingHour: 23, minute: 59, second: 59, of: now),
                let startOfTomorrow = cal.date(
                    byAdding: .day, value: 1, to: startOfDay),
                let endOfTomorrow = cal.date(
                    bySettingHour: 23, minute: 59, second: 59,
                    of: startOfTomorrow)
            else {
                DispatchQueue.main.async { self.refreshInFlight = false }
                return
            }

            // Today's events.
            let todayPredicate = self.eventStore.predicateForEvents(
                withStart: startOfDay, end: endOfDay, calendars: calendars)
            let allToday = self.eventStore.events(matching: todayPredicate)
                .sorted { $0.startDate < $1.startDate }
            let todayFiltered = self.filterEvents(
                allToday, allowList: allow, denyList: deny)
            let todayUpcoming = todayFiltered.filter { $0.endDate >= now }

            // Next event (from now through end of day).
            let nextPredicate = self.eventStore.predicateForEvents(
                withStart: now, end: endOfDay, calendars: calendars)
            let nextRange = self.eventStore.events(matching: nextPredicate)
                .sorted { $0.startDate < $1.startDate }
            let nextFiltered = self.filterEvents(
                nextRange, allowList: allow, denyList: deny)
            let nextEvent =
                nextFiltered.first(where: { !$0.isAllDay }) ?? nextFiltered.first

            // Tomorrow's events.
            let tomorrowPredicate = self.eventStore.predicateForEvents(
                withStart: startOfTomorrow, end: endOfTomorrow,
                calendars: calendars)
            let tomorrowEvents = self.eventStore.events(
                matching: tomorrowPredicate
            ).sorted { $0.startDate < $1.startDate }
            let tomorrowFiltered = self.filterEvents(
                tomorrowEvents, allowList: allow, denyList: deny)

            DispatchQueue.main.async {
                self.todaysEvents = todayUpcoming
                self.nextEvent = nextEvent
                self.tomorrowsEvents = tomorrowFiltered
                self.refreshInFlight = false
            }
        }
    }

    /// Kept for source compatibility — manual refresh entry points.
    func fetchNextEvent() { refresh() }
    func fetchTodaysEvents() { refresh() }
    func fetchTomorrowsEvents() { refresh() }
}
