import EventKit
import SwiftUI

struct TimeWidget: View {
    @EnvironmentObject var configProvider: ConfigProvider
    var config: ConfigData { configProvider.config }
    var calendarConfig: ConfigData? { config["calendar"]?.dictionaryValue }

    var format: String { config["format"]?.stringValue ?? "E d, J:mm" }
    var timeZone: String? { config["time-zone"]?.stringValue }

    var calendarFormat: String {
        calendarConfig?["format"]?.stringValue ?? "J:mm"
    }
    var calendarShowEvents: Bool {
        calendarConfig?["show-events"]?.boolValue ?? true
    }

    private let calendarManager = CalendarManager.shared

    @State private var rect = CGRect()

    var body: some View {
        // TimelineView ticks on whole seconds without a Combine timer and
        // pauses automatically while the view is off screen.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .trailing, spacing: 0) {
                Text(formattedTime(pattern: format, from: context.date))
                    .fontWeight(.semibold)
                if let event = calendarManager.nextEvent, calendarShowEvents {
                    Text(eventText(for: event))
                        .opacity(0.8)
                        .font(.subheadline)
                }
            }
        }
        .font(.headline)
        .foregroundStyle(.foregroundOutside)
        .shadow(color: .foregroundShadowOutside, radius: 3)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            rect = $0
        }
        .onAppear { calendarManager.updateConfig(config) }
        .onChange(of: configProvider.config) { _, newConfig in
            calendarManager.updateConfig(newConfig)
        }
        .experimentalConfiguration(cornerRadius: 15)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.001))
        .monospacedDigit()
        .onTapGesture {
            MenuBarPopup.show(rect: rect, id: "calendar") {
                CalendarPopup(
                    calendarManager: calendarManager,
                    configProvider: configProvider)
            }
        }
    }

    // Format the current time.
    private func formattedTime(pattern: String, from time: Date) -> String {
        DateFormatterCache.formatter(template: pattern, timeZone: timeZone)
            .string(from: time)
    }

    // Create text for the calendar event.
    private func eventText(for event: EKEvent) -> String {
        var text = event.title ?? ""
        if !event.isAllDay {
            text += " ("
            text += formattedTime(
                pattern: calendarFormat, from: event.startDate)
            text += ")"
        }
        return text
    }
}

struct TimeWidget_Previews: PreviewProvider {
    static var previews: some View {
        let provider = ConfigProvider(config: ConfigData())

        ZStack {
            TimeWidget()
                .environmentObject(provider)
        }.frame(width: 500, height: 100)
    }
}

/// `DateFormatter` creation is costly; the bar re-renders the clock every
/// second, so formatters are cached per template/time zone.
@MainActor
private enum DateFormatterCache {
    private static var cache: [String: DateFormatter] = [:]

    static func formatter(template: String, timeZone: String?)
        -> DateFormatter
    {
        let key = "\(template)|\(timeZone ?? "")|\(TimeZone.current.identifier)"
        if let cached = cache[key] { return cached }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatter.timeZone =
            timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        cache[key] = formatter
        return formatter
    }
}
