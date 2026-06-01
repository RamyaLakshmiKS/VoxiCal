import XCTest

@MainActor
final class CreateCalendarEventToolTests: XCTestCase {
    private var mock: MockCalendarService!
    private var tool: CreateCalendarEventTool!

    override func setUp() {
        super.setUp()
        mock = MockCalendarService()
        tool = CreateCalendarEventTool(calendarService: mock)
    }

    override func tearDown() {
        tool = nil
        mock = nil
        super.tearDown()
    }

    func testCreatesEventWhenAllRequiredDetailsAreProvided() async throws {
        let arguments = CreateCalendarEventTool.Arguments(
            title: "Team sync",
            startISO: "2026-06-01T15:00",
            durationMinutes: 30,
            location: "Zoom",
            notes: "Weekly sync"
        )

        let response = try await tool.call(arguments: arguments)

        XCTAssertEqual(mock.fetchCallCount, 1)
        XCTAssertEqual(mock.createCallCount, 1)
        XCTAssertTrue(response.contains("Created 'Team sync'"))
        XCTAssertEqual(mock.lastCreatedEvent?.title, "Team sync")
        XCTAssertEqual(mock.lastCreatedEvent?.location, "Zoom")
        XCTAssertEqual(mock.lastCreatedEvent?.notes, "Weekly sync")
    }

    func testReturnsMessageAndDoesNotCreateWhenDurationIsMissing() async throws {
        let arguments = CreateCalendarEventTool.Arguments(
            title: "Team sync",
            startISO: "2026-06-01T15:00",
            durationMinutes: nil,
            location: "Zoom",
            notes: nil
        )

        let response = try await tool.call(arguments: arguments)

        XCTAssertEqual(mock.fetchCallCount, 0)
        XCTAssertEqual(mock.createCallCount, 0)
        XCTAssertTrue(response.localizedCaseInsensitiveContains("duration"))
    }

    func testReturnsMessageAndDoesNotCreateWhenDateFormatIsInvalid() async throws {
        let arguments = CreateCalendarEventTool.Arguments(
            title: "Team sync",
            startISO: "June 1st at 3pm",
            durationMinutes: 30,
            location: "Zoom",
            notes: nil
        )

        let response = try await tool.call(arguments: arguments)

        XCTAssertEqual(mock.fetchCallCount, 0)
        XCTAssertEqual(mock.createCallCount, 0)
        XCTAssertTrue(response.localizedCaseInsensitiveContains("invalid date format"))
    }

    func testDetectsOverlapWhenExistingEventStartsBeforeNewEvent() async throws {
        mock.seedEvents = [
            CalendarEvent(
                id: "existing-1",
                title: "Planning session",
                startDate: makeDate("2026-06-01T14:30"),
                endDate: makeDate("2026-06-01T15:15"),
                location: "Conference Room A",
                notes: nil
            )
        ]

        let arguments = CreateCalendarEventTool.Arguments(
            title: "Team sync",
            startISO: "2026-06-01T15:00",
            durationMinutes: 30,
            location: "Zoom",
            notes: nil
        )

        let response = try await tool.call(arguments: arguments)

        XCTAssertEqual(mock.fetchCallCount, 1)
        XCTAssertEqual(mock.createCallCount, 0)
        XCTAssertTrue(response.localizedCaseInsensitiveContains("conflict"))
        XCTAssertTrue(response.localizedCaseInsensitiveContains("planning session"))
    }

    func testAllowsBackToBackEventsThatOnlyTouchAtTheBoundary() async throws {
        mock.seedEvents = [
            CalendarEvent(
                id: "existing-1",
                title: "Planning session",
                startDate: makeDate("2026-06-01T14:30"),
                endDate: makeDate("2026-06-01T15:00"),
                location: "Conference Room A",
                notes: nil
            )
        ]

        let arguments = CreateCalendarEventTool.Arguments(
            title: "Team sync",
            startISO: "2026-06-01T15:00",
            durationMinutes: 30,
            location: "Zoom",
            notes: nil
        )

        let response = try await tool.call(arguments: arguments)

        XCTAssertEqual(mock.fetchCallCount, 1)
        XCTAssertEqual(mock.createCallCount, 1)
        XCTAssertTrue(response.localizedCaseInsensitiveContains("created"))
    }

    private func makeDate(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: iso)!
    }
}