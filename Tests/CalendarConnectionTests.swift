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
    func testConsumerGoogleExchangeUsesHostedRegistrationAndNativeSessionOnly() throws {
        let fields = ["client_id": CalendarAccountConnection.googleClientID, "grant_type": "authorization_code", "code": "fictional-code", "code_verifier": String(repeating: "v", count: 43), "redirect_uri": "http://127.0.0.1:54321/auth/callback"]
        let request = try CalshotAccountService.googleCalendarTokenRequest(fields, accessToken: "fictional-session")
        XCTAssertEqual(request.url?.absoluteString, "https://calshot-oauth.vercel.app/api/google-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fictional-session")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        XCTAssertEqual(sent, fields)
        XCTAssertNil(sent["client_secret"])
        XCTAssertThrowsError(try CalshotAccountService.googleCalendarTokenRequest(["client_id": "foreign", "grant_type": "authorization_code"], accessToken: "fictional-session"))
    }

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
        // Calendars are read concurrently; every one is searched, and results keep calendar order (checked above).
        XCTAssertEqual(Set(searched), ["apple", "google", "outlook"]); XCTAssertEqual(searched.count, 3)
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
    func testLegacySnapshotDecodesWithoutIdentityMetadata() throws {
        let json = #"{"eventIdentifier":"fixture","title":"Class","start":0,"end":3600,"isAllDay":false,"calendarName":"School"}"#
        let event = try JSONDecoder().decode(CalendarEventSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(event.originalOccurrenceStart); XCTAssertNil(event.recurrenceDate)
        XCTAssertNil(event.isRecurring); XCTAssertNil(event.modifiedAt)
    }

    func testGoogleMovedOccurrencesKeepOriginalAnchorAndRevision() throws {
        let account = account(), route = RemoteCalendarService.Route(accountID: UUID(), calendarID: "School")
        let calendar = CalendarDestinationInfo(id: route.calendarIdentifier, title: "School", provider: .google, isReadOnly: true, timeZone: "America/Toronto")
        var value: [String: Any] = ["id": "moved", "summary": "Class", "recurringEventId": "series",
            "start": ["date": "2026-11-03"], "end": ["date": "2026-11-04"],
            "originalStartTime": ["date": "2026-11-01"], "updated": "2026-10-23T12:00:00.123Z"]
        let day = try RemoteCalendarService.snapshot(value, route: route, account: account, calendar: calendar)
        XCTAssertEqual(day.recurrenceDate, "2026-11-01"); XCTAssertNil(day.originalOccurrenceStart)
        XCTAssertEqual(day.isRecurring, true); XCTAssertNotNil(day.modifiedAt)
        value["originalStartTime"] = ["dateTime": "2026-11-01T09:00:00-05:00"]
        let timed = try RemoteCalendarService.snapshot(value, route: route, account: account, calendar: calendar)
        XCTAssertEqual(timed.originalOccurrenceStart, ISO8601DateFormatter().date(from: "2026-11-01T14:00:00Z"))
        XCTAssertNil(timed.recurrenceDate)
        value["originalStartTime"] = ["date": "2026-02-30"]
        XCTAssertNil(try RemoteCalendarService.snapshot(value, route: route, account: account, calendar: calendar).recurrenceDate)
    }

    func testOutlookMissingOriginalAnchorStaysUnknown() throws {
        let account = account(.outlook), route = RemoteCalendarService.Route(accountID: UUID(), calendarID: "School")
        var value: [String: Any] = ["id": "exception", "type": "exception", "start": ["dateTime": "2026-10-23T14:00:00Z"], "end": ["dateTime": "2026-10-23T15:00:00Z"]]
        let calendar = CalendarDestinationInfo(id: route.calendarIdentifier, title: "School", provider: .outlook, isReadOnly: true)
        let unknown = try RemoteCalendarService.snapshot(value, route: route, account: account, calendar: calendar)
        XCTAssertEqual(unknown.isRecurring, true); XCTAssertNil(unknown.originalOccurrenceStart)
        value["originalStart"] = "2026-10-22T13:00:00Z"
        value["lastModifiedDateTime"] = "2026-10-23T12:00:00Z"
        let known = try RemoteCalendarService.snapshot(value, route: route, account: account, calendar: calendar)
        XCTAssertNotEqual(known.originalOccurrenceStart, known.start); XCTAssertNotNil(known.modifiedAt)
    }

    func testICloudRouteRejectsSiblingCalendarResources() {
        let calendar = URL(string: "https://caldav.icloud.com/fixture/school/")!
        let valid = ICloudCalendarService.Route(accountID: UUID(), calendar: calendar, resource: calendar.appendingPathComponent("event.ics"))
        XCTAssertNotNil(ICloudCalendarService.Route(id: valid.eventID))
        for path in ["https://caldav.icloud.com/fixture/other/event.ics", "https://caldav.icloud.com/fixture/school-foreign/event.ics"] {
            let foreign = ICloudCalendarService.Route(accountID: valid.accountID, calendar: calendar, resource: URL(string: path)!)
            XCTAssertNil(ICloudCalendarService.Route(id: foreign.eventID))
        }
    }

    func testICloudMovedDateOnlyAndFloatingAnchors() throws {
        let route = ICloudCalendarService.Route(accountID: UUID(), calendar: URL(string: "https://caldav.icloud.com/fixture/")!, resource: URL(string: "https://caldav.icloud.com/fixture/event.ics")!)
        let raw = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:fictional\nDTSTART;VALUE=DATE:20261103\nDTEND;VALUE=DATE:20261104\nRECURRENCE-ID;VALUE=DATE:20261101\nLAST-MODIFIED:20261023T120000Z\nEND:VEVENT\nEND:VCALENDAR"
        let event = try XCTUnwrap(ICS(raw).events.first).snapshot(route: route, name: "School")
        XCTAssertEqual(event.recurrenceDate, "2026-11-01"); XCTAssertNil(event.originalOccurrenceStart)
        XCTAssertEqual(event.isRecurring, true); XCTAssertNotNil(event.modifiedAt)
        let floating = raw.replacingOccurrences(of: "RECURRENCE-ID;VALUE=DATE:20261101", with: "RECURRENCE-ID:20261101T090000")
        let unknown = try XCTUnwrap(ICS(floating).events.first).snapshot(route: route, name: "School")
        XCTAssertNil(unknown.originalOccurrenceStart); XCTAssertNil(unknown.recurrenceDate)
        let restored = try JSONDecoder().decode(CalendarEventSnapshot.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(restored.recurrenceDate, event.recurrenceDate); XCTAssertEqual(restored.modifiedAt, event.modifiedAt)
    }

    func testReadOnlyExactSourceCanBeReadButCannotBeMutatedOrCrossRouted() async throws {
        let account = account(), route = RemoteCalendarService.Route(accountID: account.id, calendarID: "shared")
        let transport = ScriptedCalendarHTTP([
            (200, #"{"items":[{"id":"shared","summary":"School","accessRole":"reader"}]}"#),
            (200, #"{"id":"source","summary":"Class","start":{"dateTime":"2026-10-23T13:00:00Z"},"end":{"dateTime":"2026-10-23T14:00:00Z"}}"#)])
        let service = RemoteCalendarService(accountsLoader: { [account] }, accountAccess: { _ in account }, http: { try await transport.send($0) })
        _ = try await service.availableDestinations()
        let destination = CalendarDestination.direct(calendarIdentifier: route.calendarIdentifier)
        let source = try await service.event(identifier: route.identifier(event: "source"), in: destination)
        XCTAssertEqual(source?.title, "Class")
        do { try await service.delete(identifier: route.identifier(event: "source"), in: destination); XCTFail("Read-only deletion allowed") }
        catch CalendarDestinationError.calendarReadOnly {} catch { XCTFail("Unexpected error: \(error)") }
        do { _ = try await service.update(try XCTUnwrap(source).draft, identifier: route.identifier(event: "source"), in: destination); XCTFail("Read-only update allowed") }
        catch CalendarDestinationError.calendarReadOnly {} catch { XCTFail("Unexpected error: \(error)") }
        for foreign in [RemoteCalendarService.Route(accountID: UUID(), calendarID: "shared"), RemoteCalendarService.Route(accountID: account.id, calendarID: "other")] {
            do { _ = try await service.event(identifier: foreign.identifier(event: "source"), in: destination); XCTFail("Cross-source lookup allowed") }
            catch CalendarDestinationError.calendarUnavailable {} catch { XCTFail("Unexpected error: \(error)") }
        }
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testExactReadRejectsMismatchedProviderEvent() async throws {
        let account = account(), route = RemoteCalendarService.Route(accountID: account.id, calendarID: "school")
        let transport = ScriptedCalendarHTTP([
            (200, #"{"items":[{"id":"school","summary":"School","accessRole":"owner"}]}"#),
            (200, #"{"id":"other","start":{"dateTime":"2026-10-23T13:00:00Z"},"end":{"dateTime":"2026-10-23T14:00:00Z"}}"#)])
        let service = RemoteCalendarService(accountsLoader: { [account] }, accountAccess: { _ in account }, http: { try await transport.send($0) })
        _ = try await service.availableDestinations()
        do { _ = try await service.event(identifier: route.identifier(event: "selected"), in: .direct(calendarIdentifier: route.calendarIdentifier)); XCTFail("Wrong provider event accepted") }
        catch CalendarDestinationError.calendarUnavailable {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testSourceReadRejectsWrongResolvedAccountBeforeSendingRequest() async throws {
        let account = account(), foreign = self.account(), route = RemoteCalendarService.Route(accountID: account.id, calendarID: "school")
        let transport = ScriptedCalendarHTTP([(200, #"{"items":[{"id":"school","summary":"School","accessRole":"owner"}]}"#)])
        let service = RemoteCalendarService(accountsLoader: { [account] }, accountAccess: { _ in foreign }, http: { try await transport.send($0) })
        let calendars = try await service.availableDestinations()
        XCTAssertTrue(calendars.isEmpty)
        do { _ = try await service.event(identifier: route.identifier(event: "selected"), in: .direct(calendarIdentifier: route.calendarIdentifier)); XCTFail("Foreign account accepted") }
        catch CalendarDestinationError.calendarUnavailable {} catch { XCTFail("Unexpected error: \(error)") }
        let requests = await transport.captured()
        XCTAssertTrue(requests.isEmpty)
    }

    func testInvalidProviderDateFailsInsteadOfInventingAnEvent() {
        XCTAssertThrowsError(try RemoteCalendarService.instant(["dateTime": "TBD"]))
    }

    @MainActor
    func testEventKitSelectedOccurrenceDoesNotResolveFirstSeriesOccurrence() throws {
        var first = CalendarEventSnapshot(eventIdentifier: "fictional-series", title: "Class",
            start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_003_600),
            isAllDay: false, timeZone: "America/Toronto", location: nil, calendarName: "Fixture", url: nil, notes: nil)
        first.isRecurring = true; first.originalOccurrenceStart = first.start
        var selected = first
        selected.start = first.start.addingTimeInterval(7 * 86400); selected.end = first.end.addingTimeInterval(7 * 86400)
        selected.originalOccurrenceStart = selected.start
        let result = try XCTUnwrap(EventKitCalendarService.exactOccurrence(selected, candidates: [first, selected]))
        XCTAssertEqual(result.start, selected.start)
        XCTAssertNil(EventKitCalendarService.exactOccurrence(selected, candidates: [first]))
        XCTAssertNil(EventKitCalendarService.exactOccurrence(selected, candidates: [selected, selected]))
        var changed = selected; changed.start = selected.start.addingTimeInterval(3600)
        XCTAssertEqual(EventKitCalendarService.exactOccurrence(selected, candidates: [first, changed])?.start, changed.start)
        // The caller's complete fingerprint check must reject changed source data.
        XCTAssertNotEqual(try CalshotModel.taskSourceFingerprint(changed), try CalshotModel.taskSourceFingerprint(selected))
    }

    func testEventKitOccurrenceLookupRequiresOneTypedAnchorAndExactIdentifier() {
        var selected = CalendarEventSnapshot(eventIdentifier: "fictional-all-day", title: "Deadline",
            start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_086_400),
            isAllDay: true, timeZone: nil, location: nil, calendarName: "Fixture", url: nil, notes: nil)
        selected.isRecurring = true; selected.recurrenceDate = "2027-01-15"
        var other = selected; other.recurrenceDate = "2027-01-08"
        XCTAssertEqual(EventKitCalendarService.exactOccurrence(selected, candidates: [other, selected])?.recurrenceDate, "2027-01-15")
        other = selected; other.eventIdentifier = "different-series"
        XCTAssertNil(EventKitCalendarService.exactOccurrence(selected, candidates: [other]))
        var unknown = selected; unknown.recurrenceDate = nil
        XCTAssertNil(EventKitCalendarService.exactOccurrence(unknown, candidates: [unknown]))
        var ambiguous = selected; ambiguous.originalOccurrenceStart = selected.start
        XCTAssertNil(EventKitCalendarService.exactOccurrence(ambiguous, candidates: [ambiguous]))
        var ordinary = selected; ordinary.isRecurring = false
        XCTAssertNil(EventKitCalendarService.exactOccurrence(ordinary, candidates: [ordinary]))
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
