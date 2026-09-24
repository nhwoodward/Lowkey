import XCTest
@testable import Lowkey

final class HistoryFormatTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testDayTitlesAreRelativeNearTodayAndShowTheYearOnlyWhenItDiffers() {
        let now = date(2026, 9, 23, 9)
        XCTAssertEqual(HistoryFormat.dayTitle(for: date(2026, 9, 23, 0), now: now, calendar: calendar), "Today")
        XCTAssertEqual(HistoryFormat.dayTitle(for: date(2026, 9, 22, 23), now: now, calendar: calendar), "Yesterday")
        let sameYear = HistoryFormat.dayTitle(for: date(2026, 9, 7), now: now, calendar: calendar)
        XCTAssertTrue(sameYear.contains("September 7"), sameYear)
        XCTAssertFalse(sameYear.contains("2026"), sameYear)
        let lastYear = HistoryFormat.dayTitle(for: date(2025, 12, 31), now: now, calendar: calendar)
        XCTAssertTrue(lastYear.contains("2025"), lastYear)
    }

    func testDurationNeverShowsZeroOrNonsense() {
        XCTAssertEqual(HistoryFormat.duration(0), HistoryFormat.duration(1))
        XCTAssertEqual(HistoryFormat.duration(-5), HistoryFormat.duration(1))
        XCTAssertEqual(HistoryFormat.duration(.nan), HistoryFormat.duration(1))
        XCTAssertTrue(HistoryFormat.duration(14.4).contains("14"))
    }

    func testLanguageIsNamedOnlyWhenItSaysSomething() {
        XCTAssertNil(HistoryFormat.languageName("en"))
        XCTAssertNil(HistoryFormat.languageName("auto"))
        XCTAssertNil(HistoryFormat.languageName(""))
        XCTAssertEqual(HistoryFormat.languageName("es"), "Spanish")
    }
}
