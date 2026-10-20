import Foundation

enum AppDateFormat {
  /// Include the year for older comments and records; keep the user's local time zone.
  static let timestamp = Date.FormatStyle.dateTime
    .year().month(.twoDigits).day(.twoDigits).hour().minute()
    .locale(Locale(identifier: "zh_CN"))
}
