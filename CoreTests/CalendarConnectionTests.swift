import XCTest
@testable import Calshot

private actor ScriptedCalendarHTTP {
    var requests: [URLRequest] = []
    var responses: [(Int, String)]
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let response = responses.removeFirst()
        return (Data(response.1.utf8), HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!)
    }
    func captured() -> [URLRequest] { requests }
}
final class CalendarConnectionTests: XCTestCase {
    func testGoogleCodeAndRefreshRequestsIncludeDesktopSecretAndPreservePKCE() throws {
        for grant in ["authorization_code", "refresh_token"] {
            let request = try CalendarAccountConnection.tokenRequest(provider: .google,
                fields: ["grant_type": grant, "client_id": "desktop", "code_verifier": "verifier+value", "refresh_token": "refresh"], clientSecret: "secret+&value")
            var components = URLComponents()
            components.percentEncodedQuery = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)
            let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(fields["client_secret"], "secret+&value")
            XCTAssertEqual(fields["code_verifier"], "verifier+value")
            XCTAssertEqual(fields["grant_type"], grant)
            XCTAssertEqual(request.url?.host, "oauth2.googleapis.com")
        }
        XCTAssertThrowsError(try CalendarAccountConnection.tokenRequest(provider: .google, fields: ["client_id": "desktop"], clientSecret: nil))
        let microsoft = try CalendarAccountConnection.tokenRequest(provider: .outlook, fields: ["client_id": "public-client"], clientSecret: nil)
        XCTAssertFalse(String(data: microsoft.httpBody!, encoding: .utf8)!.contains("client_secret"))
    }
    private func account(_ provider: CalendarAccountConnection.Provider = .google) -> CalendarAccountConnection.Account {
        .init(id: UUID(), provider: provider, email: "calendar@example.com", subject: "test", clientID: "desktop-test", accessToken: "fixture-token", refreshToken: "fixture-refresh", expiresAt: .distantFuture)
    }
    @MainActor
    func testAllCalendarSearchIncludesReadOnlyAndReportsDeniedSources() async throws {
        let service = MultipleCalendarFixture()
        let names = [CalendarDestinationInfo(id: "apple", title: "Apple", provider: .apple, isReadOnly: false),
                     CalendarDestinationInfo(id: "google", title: "Google", provider: .google, isReadOnly: true),
                     CalendarDestinationInfo(id: "outlook", title: "Outlook", provider: .outlook, isReadOnly: true)]
        let tools = CalendarAgentToolExecutor(service: service, coordinator: CalendarActionCoordinator(service: service),
            destination: { nil }, searchDestinations: { names }, screenText: { "" })
        let session = UUID(); tools.activate(sessionID: session)
        let raw = await tools.execute(name: "search_events", arguments: .object([:]), sessionID: session)
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)).objectValue
        XCTAssertEqual(result?["partial"], .bool(true))
        XCTAssertEqual(result?["events"]?.arrayValue?.count, 1) // same UID and occurrence via two transports
        XCTAssertEqual(result?["calendars"]?.arrayValue?.count, 3)
        XCTAssertTrue(result?["calendars"]?.arrayValue?.last?.objectValue?["error"]?.stringValue?.contains("calendar access") == true)
        let searched = await service.searched
        XCTAssertEqual(searched, ["apple", "google", "outlook"])
    }

    func testICloudDAVDiscoveryAndPrivilegeParsing() throws {
        let xml = #"<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:href>/user/calendars/school/</d:href><d:propstat><d:prop><d:displayname>School &amp; Work</d:displayname><d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:current-user-privilege-set><d:privilege><d:write/></d:privilege></d:current-user-privilege-set></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"#
        let response = try XCTUnwrap(DAVResponse.parse(Data(xml.utf8)).first)
        XCTAssertTrue(response.isCalendar); XCTAssertTrue(response.canWrite)
        XCTAssertEqual(response.properties["displayname"], "School & Work")
        XCTAssertEqual(response.href, "/user/calendars/school/")
        let principal = #"<d:multistatus xmlns:d="DAV:"><d:response><d:href>/</d:href><d:propstat><d:prop><d:current-user-principal><d:href>/user/principal/</d:href></d:current-user-principal></d:prop></d:propstat></d:response></d:multistatus>"#
        XCTAssertEqual(try DAVResponse.parse(Data(principal.utf8)).first?.properties["current-user-principal"], "/user/principal/")
    }
    func testICloudChangesOnlyOneRecurringOccurrence() throws {
        var document = ICS("BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:class-uid\nSUMMARY:Class\nDTSTART;TZID=America/Toronto:20261015T090000\nDTEND;TZID=America/Toronto:20261015T100000\nRRULE:FREQ=WEEKLY\nEND:VEVENT\nEND:VCALENDAR")
        let start = ISO8601DateFormatter().date(from: "2026-10-22T13:00:00Z")!
        var draft = EventDraft(title: "Renamed class", startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false, timeZoneIdentifier: "America/Toronto", location: nil, url: nil, notes: nil, sourceText: "Confirmed", confidence: 1, ambiguities: [])
        draft.changedFieldNames = ["title"]
        try document.change(draft, recurrence: "RECURRENCE-ID:20261022T130000Z", deleting: false)
        XCTAssertEqual(document.events.count, 2)
        XCTAssertEqual(document.events.first?.value("RRULE"), "FREQ=WEEKLY")
        XCTAssertEqual(document.events.first?.value("SUMMARY"), "Class")
        let override = try XCTUnwrap(document.events.last)
        XCTAssertNil(override.value("RRULE"))
        XCTAssertEqual(override.line("RECURRENCE-ID"), "RECURRENCE-ID;TZID=America/Toronto:20261022T090000")
        XCTAssertEqual(try ICS.Component.parseDate(override.line("DTSTART")!), start)
        XCTAssertEqual(override.value("SUMMARY"), "Renamed class")
        try document.change(draft, recurrence: "RECURRENCE-ID:20261022T130000Z", deleting: true)
        XCTAssertEqual(document.events.count, 2)
        XCTAssertEqual(document.events.last?.value("STATUS"), "CANCELLED")
        XCTAssertNil(document.events.first?.value("STATUS"))
    }
    func testICloudLineFoldingEscapingAndAllDayTimezoneRoundTrip() throws {
        let start = ISO8601DateFormatter().date(from: "2026-10-15T04:00:00Z")!
        let title = String(repeating: "📅", count: 40) + ", Class; confirmed\nNext line"
        let draft = EventDraft(title: title, startDate: start, endDate: start.addingTimeInterval(86400), isAllDay: true, timeZoneIdentifier: "America/Toronto", location: nil, url: nil, notes: nil, sourceText: "Confirmed", confidence: 1, ambiguities: [])
        let encoded = try ICS.new(draft)
        XCTAssertTrue(encoded.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        let component = try XCTUnwrap(ICS(encoded).events.first)
        let route = ICloudCalendarService.Route(accountID: UUID(), calendar: URL(string: "https://p42-caldav.icloud.com/user/calendars/school/")!, resource: URL(string: "https://p42-caldav.icloud.com/user/calendars/school/event.ics")!)
        let restored = try component.snapshot(route: route, name: "School")
        XCTAssertEqual(restored.title, title)
        XCTAssertEqual(restored.start, start); XCTAssertEqual(restored.end, draft.endDate)
        XCTAssertEqual(restored.timeZone, "America/Toronto"); XCTAssertTrue(restored.isAllDay)
    }
    func testICloudRejectsCredentialsToNonAppleHosts() {
        XCTAssertFalse(ICloudCalendarService.allowed(URL(string: "https://caldav.icloud.com.example.org/calendar/")!))
        XCTAssertFalse(ICloudCalendarService.allowed(URL(string: "http://caldav.icloud.com/calendar/")!))
        XCTAssertFalse(ICloudCalendarService.allowed(URL(string: "https://user:password@caldav.icloud.com/calendar/")!))
        XCTAssertTrue(ICloudCalendarService.allowed(URL(string: "https://p42-caldav.icloud.com/calendar/")!))
    }

    func testDeniedDirectCalendarCatalogPreservesAccountFailure() async throws {
        let account = account(.outlook)
        let transport = ScriptedCalendarHTTP([(403, #"{"error":{"message":"Calendar access blocked by organization"}}"#)])
        let service = RemoteCalendarService(accountsLoader: { [account] }, accountAccess: { _ in account }, http: { try await transport.send($0) })
        let calendars = try await service.availableDestinations()
        XCTAssertTrue(calendars.isEmpty)
        let errors = await service.accountErrors
        XCTAssertTrue(errors[account.id]?.contains("403") == true)
        XCTAssertTrue(errors[account.id]?.contains("blocked by organization") == true)
    }
    func testICloudCalendarHomeParser() throws {
        let xml = #"<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:href>/principal/</d:href><d:propstat><d:prop><c:calendar-home-set><d:href>https://p42-caldav.icloud.com/user/calendars/</d:href></c:calendar-home-set></d:prop></d:propstat></d:response></d:multistatus>"#
        XCTAssertEqual(try DAVResponse.parse(Data(xml.utf8)).first?.properties["calendar-home-set"], "https://p42-caldav.icloud.com/user/calendars/")
    }

    func testPartialOAuthConsentCannotMasqueradeAsCalendarAccess() {
        XCTAssertFalse(CalendarAccountConnection.hasCalendarScopes(provider: .google, scope: "openid email https://www.googleapis.com/auth/calendar.calendarlist.readonly"))
        XCTAssertTrue(CalendarAccountConnection.hasCalendarScopes(provider: .google, scope: "openid https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly"))
        XCTAssertFalse(CalendarAccountConnection.hasCalendarScopes(provider: .outlook, scope: "openid User.Read"))
        XCTAssertTrue(CalendarAccountConnection.hasCalendarScopes(provider: .outlook, scope: "openid User.Read Calendars.ReadWrite"))
    }

    func testRouteKeepsAccountCalendarAndEventIdentity() throws {
        let original = RemoteCalendarService.Route(accountID: UUID(), calendarID: "Shared calendar / A+B@example.com", eventID: "instance/1")
        let encoded = original.identifier(event: original.eventID!)
        let decoded = try XCTUnwrap(RemoteCalendarService.Route(identifier: encoded))
        XCTAssertEqual(decoded.accountID, original.accountID)
        XCTAssertEqual(decoded.calendarID, original.calendarID)
        XCTAssertEqual(decoded.eventID, original.eventID)
        XCTAssertNil(RemoteCalendarService.Route(identifier: "remote:not-a-uuid:invalid"))
    }
    func testGooglePaginationAndCreateUseOneTransportAndStableEventID() async throws {
        let account = account()
        let transport = ScriptedCalendarHTTP([
            (200, #"{"items":[{"id":"primary","summary":"School","accessRole":"owner","timeZone":"America/Toronto"}],"nextPageToken":"next"}"#),
            (200, #"{"items":[{"id":"shared","summary":"Read only","accessRole":"reader"}]}"#),
            (200, #"{"id":"created-event"}"#)])
        let service = RemoteCalendarService(accountsLoader: { [account] }, accountAccess: { _ in account }, http: { try await transport.send($0) })
        let calendars = try await service.availableDestinations()
        XCTAssertEqual(calendars.count, 2)
        XCTAssertEqual(calendars.filter(\.isReadOnly).count, 1)
        let destination = try XCTUnwrap(calendars.first { !$0.isReadOnly })
        let draft = EventDraft(title: "Deadline", startDate: Date(timeIntervalSince1970: 1_800_000_000), endDate: Date(timeIntervalSince1970: 1_800_003_600), isAllDay: false, timeZoneIdentifier: "America/Toronto", location: nil, url: nil, notes: nil, sourceText: "Confirmed", confidence: 1, ambiguities: [])
        let id = try await service.save(draft, to: .eventKit(calendarIdentifier: destination.id))
        XCTAssertEqual(RemoteCalendarService.Route(identifier: id)?.eventID, "created-event")
        let requests = await transport.captured()
        XCTAssertTrue(requests[1].url!.absoluteString.contains("pageToken=next"))
        XCTAssertEqual(requests[2].httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: Any])
        XCTAssertEqual(body["id"] as? String, draft.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased())
    }
    func testOutlookSnapshotPreservesOccurrenceAndIdentity() throws {
        let account = account(.outlook)
        let route = RemoteCalendarService.Route(accountID: account.id, calendarID: "School")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"id":"occurrence-1","subject":"Class","iCalUId":"uid-1","isAllDay":false,"start":{"dateTime":"2026-10-15T09:00:00.0000000","timeZone":"America/Toronto"},"end":{"dateTime":"2026-10-15T10:00:00.0000000","timeZone":"America/Toronto"}}"#.utf8)) as? [String: Any])
        let event = try RemoteCalendarService.snapshot(value, route: route, account: account, calendar: .init(id: route.calendarIdentifier, title: "School", provider: .outlook, isReadOnly: false))
        XCTAssertEqual(event.externalEventIdentifier, "uid-1")
        XCTAssertEqual(event.start, ISO8601DateFormatter().date(from: "2026-10-15T13:00:00Z"))
        XCTAssertEqual(event.end.timeIntervalSince(event.start), 3600)
    }
    @MainActor
    func testDeduplicationKeepsDistinctRecurringOccurrences() {
        let first = CalendarEventSnapshot(eventIdentifier: "eventkit-a", title: "Class", start: .now, end: .now.addingTimeInterval(3600), isAllDay: false, timeZone: nil, location: nil, calendarName: "School", url: nil, notes: nil, externalEventIdentifier: "same-uid")
        var duplicate = first; duplicate.eventIdentifier = "google-a"
        var next = first; next.start = next.start.addingTimeInterval(86400); next.end = next.end.addingTimeInterval(86400)
        XCTAssertEqual(CalendarAgentToolExecutor.occurrenceKey(first), CalendarAgentToolExecutor.occurrenceKey(duplicate))
        XCTAssertNotEqual(CalendarAgentToolExecutor.occurrenceKey(first), CalendarAgentToolExecutor.occurrenceKey(next))
    }
    func testInvalidProviderDateFailsInsteadOfInventingAnEvent() {
        XCTAssertThrowsError(try RemoteCalendarService.instant(["dateTime": "TBD"]))
    }
}

private actor MultipleCalendarFixture: CalendarDestinationService {
    var searched: [String] = []
    func availableDestinations() async throws -> [CalendarDestinationInfo] { [] }
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] { [] }
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String { throw CalendarDestinationError.calendarReadOnly }
    func searchEvents(query: String?, start: Date, end: Date, in destination: CalendarDestination) async throws -> [CalendarEventSnapshot] {
        guard case .eventKit(let id) = destination else { return [] }
        searched.append(id)
        if id == "outlook" { throw CalendarDestinationError.permissionDenied }
        return [.init(eventIdentifier: id + "-event", title: "Class", start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_003_600), isAllDay: false, timeZone: nil, location: nil, calendarName: id, url: nil, notes: nil, externalEventIdentifier: "shared-uid")]
    }
}
