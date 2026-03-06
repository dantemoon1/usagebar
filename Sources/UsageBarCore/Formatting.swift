import Foundation

public enum UsageBarFormatting {
    /// Format for 5h window: "3:00 PM" (today), "tomorrow 2:00 AM", "Mon 2:00 AM"
    public static func shortResetText(for date: Date?) -> String {
        guard let date else { return "Unavailable" }
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) {
            return time
        } else if cal.isDateInTomorrow(date) {
            return "tomorrow \(time)"
        } else {
            let day = date.formatted(.dateTime.weekday(.abbreviated))
            return "\(day) \(time)"
        }
    }

    /// Format for 7-day window: "today 11:00 AM", "Mar 12 at 11:00 AM"
    public static func longResetText(for date: Date?) -> String {
        guard let date else { return "Unavailable" }
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) {
            return "today \(time)"
        } else if cal.isDateInTomorrow(date) {
            return "tomorrow \(time)"
        } else {
            let day = date.formatted(.dateTime.month(.abbreviated).day())
            return "\(day) at \(time)"
        }
    }

    public static func shortDateTimeText(for date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
    
    public static func groupedNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func currencyUSD(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$\(value)"
    }
}
