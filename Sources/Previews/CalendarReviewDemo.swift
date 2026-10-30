#if DEBUG
import AppKit
import Foundation

/// An isolated, offline review fixture for checking native layout and interaction.
/// Demo receipts never reach the user's calendars or normal capture history.
actor CalendarDemoService: CalendarDestinationService {
    private var items: [EventDraft] = []
    func availableDestinations() async throws -> [CalendarDestinationInfo] {
        [CalendarDestinationInfo(id: "demo", title: "Demo Calendar (local fixture)", provider: .apple, isReadOnly: false)]
    }
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] {
        items.filter { CalendarDraftValidation.sameEvent($0, draft) }.map { $0.id.uuidString }
    }
    func searchEvents(query: String?, start: Date, end: Date, in destination: CalendarDestination) async throws -> [CalendarEventSnapshot] {
        items.filter { ($0.startDate ?? .distantPast) < end && ($0.endDate ?? .distantFuture) > start && CalendarSearchMatch.matches(query, title: $0.title, notes: $0.notes, location: $0.location) }.prefix(CalendarSearchMatch.resultLimit).compactMap(snapshot)
    }
    func event(identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? {
        items.first { $0.id.uuidString == identifier }.flatMap(snapshot)
    }
    func update(_ draft: EventDraft, identifier: String, in destination: CalendarDestination) async throws -> String {
        guard let index = items.firstIndex(where: { $0.id.uuidString == identifier }) else { throw CalendarDestinationError.calendarUnavailable }
        var changed = draft
        changed.id = items[index].id
        items[index] = changed
        return identifier
    }
    func delete(identifier: String, in destination: CalendarDestination) async throws {
        guard let index = items.firstIndex(where: { $0.id.uuidString == identifier }) else { throw CalendarDestinationError.calendarUnavailable }
        items.remove(at: index)
    }
    private func snapshot(_ draft: EventDraft) -> CalendarEventSnapshot? {
        guard let start = draft.startDate, let end = draft.endDate else { return nil }
        return CalendarEventSnapshot(eventIdentifier: draft.id.uuidString, title: draft.title, start: start, end: end,
                                     isAllDay: draft.isAllDay, timeZone: draft.timeZoneIdentifier, location: draft.location,
                                     calendarName: "Demo Calendar", url: draft.url, notes: draft.notes)
    }
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String {
        items.append(draft)
        return draft.id.uuidString
    }
}

extension CalshotModel {
    func loadCalendarDemo() {
        let text = """
        BIO 101 — Fall 2026
        Assignments and examinations
        Assignment 1 | October 16, 2026
        Assignment 2 | October 23, 2026
        Lab report | October 30, 2026 | 11:59 PM
        Midterm exam | November 6, 2026 | 10:00 AM - 11:30 AM
        Essay submission | November 13, 2026
        Final exam | December 15, 2026 | 2:00 PM - 4:00 PM
        Quiz | TBD
        """
        let image = NSImage(size: NSSize(width: 1100, height: 650))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1100, height: 650).fill()
        (text as NSString).draw(in: NSRect(x: 45, y: 40, width: 1000, height: 560), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 21, weight: .regular), .foregroundColor: NSColor.black
        ])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        do {
            let drafts = EventDraftParser.parse(text)
            let record = try MemoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("CalshotCalendarDemo"))
                .recordCapture(imageData: png, proposals: drafts.map(CalendarActionProposal.init(draft:)),
                               recognizedText: text, analysisProvider: "Offline demo fixture")
            restoreCalendarReview(record)
            status = "Demo fixture — additions stay in the demo service, outside your calendars."
        } catch { status = error.localizedDescription }
    }
}
#endif
