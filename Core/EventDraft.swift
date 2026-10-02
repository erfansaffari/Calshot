import Foundation

/// A provider-independent event proposal. Dates are optional until the review UI
/// has enough information (or the user fills in a missing value).
public struct EventDraft: Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var startDate: Date?
    public var endDate: Date?
    public var isAllDay: Bool
    public var timeZoneIdentifier: String?
    public var location: String?
    public var url: URL?
    public var notes: String?
    public var sourceText: String
    public var confidence: Double
    public var ambiguities: [EventAmbiguity]

    public init(id: UUID = UUID(), title: String, startDate: Date?, endDate: Date?, isAllDay: Bool,
                timeZoneIdentifier: String?, location: String?, url: URL?, notes: String?,
                sourceText: String, confidence: Double, ambiguities: [EventAmbiguity]) {
        self.id = id; self.title = title; self.startDate = startDate; self.endDate = endDate
        self.isAllDay = isAllDay; self.timeZoneIdentifier = timeZoneIdentifier; self.location = location
        self.url = url; self.notes = notes; self.sourceText = sourceText; self.confidence = confidence
        self.ambiguities = ambiguities
    }
}

public enum EventAmbiguity: String, Sendable, Hashable {
    case missingTitle
    case missingDate
    case missingYear
    case missingTime
    case ambiguousDate
    case ambiguousTime
    case ambiguousTimeZone
    case missingEndTime
    case multipleEvents
}
