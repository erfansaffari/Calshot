import XCTest
@testable import Calshot

final class EventDraftParserTests: XCTestCase {
    private let toronto = TimeZone(identifier: "America/Toronto")!

    func testParsesNamedDateTimeAndExplicitZone() throws {
        let drafts = EventDraftParser.parse(
            "Design systems meetup\nOctober 18, 2026\n6:30 PM - 8:00 PM EDT\nLocation: Studio A",
            referenceDate: date(2026, 1, 1), timeZone: toronto, locale: Locale(identifier: "en_CA"))
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(draft.title, "Design systems meetup")
        XCTAssertEqual(draft.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(draft.location, "Studio A")
        XCTAssertNotNil(draft.startDate)
        XCTAssertNotNil(draft.endDate)
        XCTAssertFalse(draft.ambiguities.contains(.missingYear))
    }

    func testFlagsYearlessAmbiguousNumericDateAndMissingEnd() throws {
        let drafts = EventDraftParser.parse(
            "Planning session\n04/05\n10:30 AM",
            referenceDate: date(2026, 1, 1), timeZone: toronto, locale: Locale(identifier: "en_CA"))
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertTrue(draft.ambiguities.contains(.missingYear))
        XCTAssertTrue(draft.ambiguities.contains(.ambiguousDate))
        XCTAssertTrue(draft.ambiguities.contains(.missingEndTime))
        XCTAssertNotNil(draft.endDate, "Single-time drafts receive a provisional one-hour duration for review.")
    }

    func testRejectsImpossibleDate() throws {
        let drafts = EventDraftParser.parse(
            "Launch\nFebruary 31, 2026\nAll-day",
            referenceDate: date(2026, 1, 1), timeZone: toronto)
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertTrue(draft.ambiguities.contains(.missingDate))
        XCTAssertFalse(draft.isAllDay)
    }

    func testISODateDoesNotBecomeATimeRange() throws {
        let drafts = EventDraftParser.parse(
            "Product launch\n2026-10-18",
            referenceDate: date(2026, 1, 1), timeZone: toronto, locale: Locale(identifier: "en_CA"))
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(draft.title, "Product launch")
        XCTAssertTrue(draft.ambiguities.contains(.missingTime))
        XCTAssertFalse(draft.ambiguities.contains(.ambiguousTime))
        let start = try XCTUnwrap(draft.startDate)
        let end = try XCTUnwrap(draft.endDate)
        XCTAssertTrue(draft.isAllDay, "Date-only text keeps the detected date visible as a provisional all-day event.")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = toronto
        XCTAssertEqual(calendar.startOfDay(for: start), start)
        XCTAssertEqual(end.timeIntervalSince(start), 24 * 60 * 60, accuracy: 1)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = toronto
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
