import Foundation

struct AgentQuestion: Identifiable {
    let id = UUID()
    let question: String
    let choices: [String]
}

@MainActor
final class CalendarAgentToolExecutor: CalendarAgentToolExecuting {
    var taskImportReceipts: ((JSONValue) -> JSONValue)?
    var finishTaskImport: (() -> Void)?
    var listTasks: (() throws -> JSONValue)?
    var createTasks: (([String: JSONValue]) throws -> (saved: JSONValue, proposals: [CalendarActionProposal]))?
    var listFriends: (() async throws -> JSONValue)?
    var searchFriend: (([String: JSONValue]) async throws -> JSONValue)?
    private let service: any CalendarDestinationService
    private let coordinator: CalendarActionCoordinator
    private let destination: () -> (id: String, name: String)?
    private let searchDestinations: (() -> [CalendarDestinationInfo])?
    private let onTargetDestination: (String) -> Void
    private let screenText: () async -> String
    private let sourceContext: () -> String
    private let sourceRegion: (String) -> SourceRegion?
    private let sourceCaptureID: () -> UUID?
    private let onApproval: (Bool) -> Void
    private let onQuestion: (AgentQuestion?) -> Void
    private let onStep: (String) -> Void
    private var sessionID: UUID?
    private var searched: [String: String] = [:]
    private var ambiguousTargets = Set<String>()
    private var cancelledTargets = Set<String>()
    private var confirmedAnswers: [String] = []
    private var approvalContinuation: CheckedContinuation<String, Never>?
    private var questionContinuation: CheckedContinuation<String, Never>?
    private var requestIDs = Set<UUID>()
    private var writeTool: String?

    init(service: any CalendarDestinationService, coordinator: CalendarActionCoordinator,
         destination: @escaping () -> (id: String, name: String)?,
         searchDestinations: (() -> [CalendarDestinationInfo])? = nil, onTargetDestination: @escaping (String) -> Void = { _ in }, screenText: @escaping () async -> String,
         sourceContext: @escaping () -> String = { "" }, sourceRegion: @escaping (String) -> SourceRegion? = { _ in nil },
         sourceCaptureID: @escaping () -> UUID? = { nil },
         onApproval: @escaping (Bool) -> Void = { _ in }, onQuestion: @escaping (AgentQuestion?) -> Void = { _ in },
         onStep: @escaping (String) -> Void = { _ in }) {
        self.searchDestinations = searchDestinations; self.onTargetDestination = onTargetDestination
        self.service = service; self.coordinator = coordinator; self.destination = destination; self.screenText = screenText
        self.sourceContext = sourceContext; self.sourceRegion = sourceRegion; self.sourceCaptureID = sourceCaptureID; self.onApproval = onApproval
        self.onQuestion = onQuestion; self.onStep = onStep
    }

    func activate(sessionID: UUID) {
        if let old = self.sessionID { cancelPending(sessionID: old) }
        self.sessionID = sessionID
        searched = [:]; ambiguousTargets = []; cancelledTargets = []; confirmedAnswers = []
    }

    func execute(name: String, arguments: JSONValue, sessionID: UUID) async -> String {
        guard self.sessionID == sessionID else { return #"{"cancelled":true}"# }
        do {
            guard let fields = arguments.objectValue else { throw CalendarToolArgumentError("Arguments must be an object.") }
            switch name {
            case "list_tasks":
                try CalendarToolDraftMapper.keys(fields, allowed: [])
                guard let listTasks else { throw CalendarToolArgumentError("Tasks are unavailable.") }
                return try listTasks().jsonString()
            case "create_tasks":
                guard let createTasks else { throw CalendarToolArgumentError("Tasks are unavailable.") }
                let result = try createTasks(fields)
                let hasNew = result.saved.arrayValue?.contains { $0.objectValue?["alreadyInTasks"] != .bool(true) } == true
                guard hasNew else { return JSONValue.object(["tasksSaved": taskImportReceipts?(result.saved) ?? .array([]), "calendar": .string("Already in Tasks. No new calendar writes.")]).jsonString() }
                coordinator.replace(with: coordinator.proposals + result.proposals)
                try coordinator.persist?(coordinator.proposals)
                let calendar = await awaitApproval(name: name, ids: Set(result.proposals.map(\.id)))
                return JSONValue.object(["tasksSaved": taskImportReceipts?(result.saved) ?? .array([]), "calendar": (try? JSONDecoder().decode(JSONValue.self, from: Data(calendar.utf8))) ?? .string(calendar)]).jsonString()
            case "list_friends":
                try CalendarToolDraftMapper.keys(fields, allowed: [])
                guard let listFriends else { throw CalendarToolArgumentError("Friend sharing is unavailable. Open Friends & sharing in Settings.") }
                onStep("Checking friends who share with you")
                let result = try await listFriends()
                guard self.sessionID == sessionID, !Task.isCancelled else { return #"{"cancelled":true}"# }
                return result.jsonString()
            case "search_friend_events":
                try CalendarToolDraftMapper.keys(fields, allowed: ["friendID", "query", "start", "end"])
                guard let id = try CalendarToolDraftMapper.string(fields, "friendID", required: true, limit: 36), UUID(uuidString: id) != nil,
                      let start = try CalendarToolDraftMapper.instant(fields, "start"), let end = try CalendarToolDraftMapper.instant(fields, "end"),
                      end > start, end.timeIntervalSince(start) <= 63 * 86400 else { throw CalendarToolArgumentError("Choose a listed friend and explicit dates covering up to 63 days.") }
                _ = try CalendarToolDraftMapper.string(fields, "query", limit: 200)
                guard let searchFriend else { throw CalendarToolArgumentError("Friend calendar reads are unavailable.") }
                onStep("Checking your friend’s shared calendars")
                let result = try await searchFriend(fields)
                guard self.sessionID == sessionID, !Task.isCancelled else { return #"{"cancelled":true}"# }
                // Friend event IDs never enter the searched targets used by write tools.
                return result.jsonString()
            case "read_screen_text":
                try CalendarToolDraftMapper.keys(fields, allowed: [])
                let text = await screenText()
                guard self.sessionID == sessionID, !Task.isCancelled else { return #"{"cancelled":true}"# }
                return JSONValue.object(["text": .string(String(text.prefix(16_000))), "truncated": .bool(text.count > 16_000)]).jsonString()
            case "search_events":
                try CalendarToolDraftMapper.keys(fields, allowed: ["query", "start", "end"])
                let query = try CalendarToolDraftMapper.string(fields, "query", limit: 500)
                let calendars: [CalendarDestinationInfo]
                if let searchDestinations { calendars = searchDestinations() }
                else {
                    let calendar = try currentDestination()
                    calendars = [.init(id: calendar.id, title: calendar.name, provider: .apple, isReadOnly: false)]
                }
                guard !calendars.isEmpty else { throw CalendarToolArgumentError("No calendars are connected. Connect an account before searching.") }
                let start = try CalendarToolDraftMapper.instant(fields, "start") ?? Date.now.addingTimeInterval(-7 * 86400)
                let end = try CalendarToolDraftMapper.instant(fields, "end") ?? Date.now.addingTimeInterval(120 * 86400)
                guard end > start, end.timeIntervalSince(start) <= 366 * 86400 else { throw CalendarToolArgumentError("Search must cover a positive range of at most 366 days.") }
                var events: [(CalendarEventSnapshot, String)] = []
                var results: [JSONValue] = []
                for calendar in calendars {
                    onStep("Searching \(calendar.title)")
                    do {
                        let found = try await service.searchEvents(query: query, start: start, end: end, in: .resolve(identifier: calendar.id))
                        guard self.sessionID == sessionID, !Task.isCancelled else { return #"{"cancelled":true}"# }
                        events.append(contentsOf: found.map { ($0, calendar.id) })
                        results.append(.object(["id": .string(calendar.id), "name": .string(calendar.title), "sourceName": .string(calendar.sourceName ?? calendar.provider.rawValue), "isReadOnly": .bool(calendar.isReadOnly), "count": .number(Double(found.count))]))
                    } catch {
                        guard self.sessionID == sessionID, !Task.isCancelled else { return #"{"cancelled":true}"# }
                        results.append(.object(["id": .string(calendar.id), "name": .string(calendar.title), "sourceName": .string(calendar.sourceName ?? calendar.provider.rawValue), "isReadOnly": .bool(calendar.isReadOnly), "error": .string(error.localizedDescription)]))
                    }
                }
                var seen = Set<String>()
                let unique = events.sorted { $0.0.start < $1.0.start }.filter { seen.insert(Self.occurrenceKey($0.0)).inserted }
                let limited = Array(unique.prefix(40))
                for (event, id) in limited { searched[event.eventIdentifier] = id }
                if limited.count > 1 { ambiguousTargets.formUnion(limited.map { $0.0.eventIdentifier }) }
                let failed = results.filter { $0.objectValue?["error"] != nil }.count
                return JSONValue.object(["events": .array(limited.map { event, id in
                    var fields = Self.eventJSON(event).objectValue ?? [:]; fields["calendarIdentifier"] = .string(id)
                    return .object(fields)
                }), "calendars": .array(results), "partial": .bool(failed > 0),
                    "error": failed == calendars.count ? .string("None of the connected calendars could be searched.") : .null,
                    "truncated": .bool(unique.count > 40 || results.contains { $0.objectValue?["count"] == .number(40) }),
                    "calendarName": .string(calendars.count == 1 ? calendars[0].title : "All connected calendars"),
                    "calendarIdentifier": calendars.count == 1 ? .string(calendars[0].id) : .null,
                    "start": .string(ISO8601DateFormatter().string(from: start)), "end": .string(ISO8601DateFormatter().string(from: end)),
                    "scope": .string(calendars.count == 1 ? "Only this selected calendar was searched; other calendars were not checked." : "All calendars available through the connected adapters were searched. Check per-calendar errors before claiming no events.")]).jsonString()
            case "ask_user":
                try CalendarToolDraftMapper.keys(fields, allowed: ["question", "choices"])
                guard let question = try CalendarToolDraftMapper.string(fields, "question", required: true, limit: 2000), !question.isEmpty else {
                    throw CalendarToolArgumentError("A question is required.")
                }
                var choices: [String] = []
                if let value = fields["choices"], value != .null {
                    guard let array = value.arrayValue, array.count <= 6 else { throw CalendarToolArgumentError("Use at most six choices.") }
                    choices = try array.map { value in
                        guard let text = value.stringValue, !text.isEmpty, text.count <= 500 else { throw CalendarToolArgumentError("Choices must be nonempty strings.") }
                        return text
                    }
                }
                guard questionContinuation == nil else { throw CalendarToolArgumentError("Another question is waiting.") }
                onStep("Waiting for your answer")
                return await withCheckedContinuation { continuation in
                    questionContinuation = continuation
                    onQuestion(AgentQuestion(question: question, choices: choices))
                }
            case "create_events":
                try CalendarToolDraftMapper.keys(fields, allowed: ["events", "calendarIdentifier"])
                guard let events = fields["events"]?.arrayValue, !events.isEmpty, events.count <= 100 else {
                    throw CalendarToolArgumentError("Provide between 1 and 100 events in one batch.")
                }
                let calendar = try resolveDestination(fields)
                onTargetDestination(calendar.id)
                let ocr = await screenText()
                guard self.sessionID == sessionID, !Task.isCancelled else { return #"{"cancelled":true}"# }
                let context = ocr + "\n" + sourceContext() + "\n" + confirmedAnswers.joined(separator: "\n")
                let drafts = try events.map { try CalendarToolDraftMapper.create($0, context: context, confirmedContext: sourceContext() + "\n" + confirmedAnswers.joined(separator: "\n")) }
                var retained = coordinator.proposals
                for index in retained.indices where !retained[index].isFinished { retained[index].isSelected = false }
                var requests: [CalendarActionProposal] = []
                var alreadyFinished: [CalendarActionProposal] = []
                for var draft in drafts {
                    draft.sourceRegion = sourceRegion(draft.sourceText)
                    if let done = retained.first(where: { $0.operation == .create && $0.isFinished && $0.receipt?.destinationID == calendar.id && CalendarDraftValidation.sameEvent($0.draft, draft) }) {
                        alreadyFinished.append(done); continue
                    }
                    if let failedIndex = retained.firstIndex(where: { $0.operation == .create && ($0.state == .failed || $0.state == .pending) && CalendarDraftValidation.sameEvent($0.draft, draft) }) {
                        draft.id = retained[failedIndex].id
                        retained.remove(at: failedIndex)
                    }
                    var proposal = CalendarActionProposal(draft: draft)
                    if fields["calendarIdentifier"] != nil && fields["calendarIdentifier"] != .null {
                        proposal.targetDestinationID = calendar.id; proposal.targetCalendarName = calendar.name
                    }
                    proposal.sourceCaptureID = sourceCaptureID()
                    requests.append(proposal)
                }
                guard !requests.isEmpty else {
                    return JSONValue.object(["added": .array([]), "failed": .array([]), "skipped": .array(alreadyFinished.map(Self.skippedJSON))]).jsonString()
                }
                coordinator.replace(with: retained + requests)
                try coordinator.persist?(coordinator.proposals)
                return await awaitApproval(name: name, ids: Set(requests.map(\.id)), extraSkipped: alreadyFinished)
            case "move_events":
                try CalendarToolDraftMapper.keys(fields, allowed: ["events", "calendarIdentifier"])
                let destination = try resolveDestination(fields, required: true)
                guard let rows = fields["events"]?.arrayValue, !rows.isEmpty, rows.count <= 40 else { throw CalendarToolArgumentError("Provide 1 to 40 searched events to move.") }
                var requests: [CalendarActionProposal] = []
                var seen = Set<String>()
                for row in rows {
                    guard let values = row.objectValue else { throw CalendarToolArgumentError("Each move must be an object.") }
                    try CalendarToolDraftMapper.keys(values, allowed: ["eventIdentifier", "existingDestinationEventIdentifier"])
                    guard let id = try CalendarToolDraftMapper.string(values, "eventIdentifier", required: true, limit: 2000), seen.insert(id).inserted,
                          let sourceID = searched[id], sourceID != destination.id else { throw CalendarToolArgumentError("Search each original first; source and destination must differ and each event must occur once.") }
                    guard searchDestinations?().first(where: { $0.id == sourceID })?.isReadOnly != true else { throw CalendarDestinationError.calendarReadOnly }
                    guard let original = try await service.event(identifier: id, in: .resolve(identifier: sourceID)) else { throw CalendarDestinationError.calendarUnavailable }
                    guard self.sessionID == sessionID, !Task.isCancelled else { return #"{"cancelled":true}"# }
                    var draft = original.draft; draft.id = UUID()
                    var proposal = CalendarActionProposal(draft: draft, operation: .move, targetEventIdentifier: id, before: original.draft)
                    proposal.sourceDestinationID = sourceID
                    proposal.sourceCalendarName = searchDestinations?().first(where: { $0.id == sourceID })?.title ?? original.calendarName
                    proposal.targetDestinationID = destination.id; proposal.targetCalendarName = destination.name
                    if let copyID = try CalendarToolDraftMapper.string(values, "existingDestinationEventIdentifier", limit: 2000) {
                        guard searched[copyID] == destination.id,
                              let copy = try await service.event(identifier: copyID, in: .resolve(identifier: destination.id)),
                              CalendarDraftValidation.sameEvent(copy.draft, draft) else { throw CalendarToolArgumentError("Search and verify the existing destination copy before reusing it.") }
                        proposal.moveCopyReceipt = CalendarActionReceipt(destinationID: destination.id, calendarName: destination.name, eventIdentifier: copyID, savedAt: .now)
                        proposal.moveDestinationBefore = copy.draft
                    }
                    requests.append(proposal)
                }
                guard self.sessionID == sessionID, !Task.isCancelled else { return #"{"cancelled":true}"# }
                var retained = coordinator.proposals
                for index in retained.indices where !retained[index].isFinished { retained[index].isSelected = false }
                onTargetDestination(destination.id)
                coordinator.replace(with: retained + requests)
                try coordinator.persist?(coordinator.proposals)
                return await awaitApproval(name: name, ids: Set(requests.map(\.id)))
            case "update_event", "delete_event":
                let allowed: Set<String> = name == "delete_event" ? ["eventIdentifier", "reason"] :
                    ["eventIdentifier", "title", "date", "startTime", "endTime", "allDay", "timeZone", "location", "url", "notes"]
                try CalendarToolDraftMapper.keys(fields, allowed: allowed)
                guard let identifier = try CalendarToolDraftMapper.string(fields, "eventIdentifier", required: true, limit: 2000), !identifier.isEmpty else {
                    throw CalendarToolArgumentError("An event identifier is required.")
                }
                if cancelledTargets.contains(identifier) { return #"{"skipped":true}"# }
                guard let calendarID = searched[identifier] else { throw CalendarToolArgumentError("Search before changing or deleting the event.") }
                if searchDestinations?().first(where: { $0.id == calendarID })?.isReadOnly == true { throw CalendarDestinationError.calendarReadOnly }
                let calendarName = searchDestinations?().first(where: { $0.id == calendarID })?.title ?? destination()?.name ?? "Calendar"
                guard !ambiguousTargets.contains(identifier) else { throw CalendarToolArgumentError("Ask the user to choose between the search matches before changing anything.") }
                guard let existing = try await service.event(identifier: identifier, in: .resolve(identifier: calendarID)) else {
                    throw CalendarDestinationError.calendarUnavailable
                }
                guard self.sessionID == sessionID, !Task.isCancelled else { return #"{"cancelled":true}"# }
                let before = existing.draft
                var proposal: CalendarActionProposal
                if name == "update_event" {
                    guard fields.keys.contains(where: { $0 != "eventIdentifier" }) else { throw CalendarToolArgumentError("Provide at least one changed field.") }
                    let changed = try CalendarToolDraftMapper.update(fields, before: before)
                    proposal = CalendarActionProposal(draft: changed, operation: .update, targetEventIdentifier: identifier, before: before)
                } else {
                    guard let reason = try CalendarToolDraftMapper.string(fields, "reason", required: true, limit: 2000), !reason.isEmpty else {
                        throw CalendarToolArgumentError("Explain why this event should be removed.")
                    }
                    var removed = before; removed.id = UUID(); removed.sourceText = reason
                    proposal = CalendarActionProposal(draft: removed, operation: .delete, targetEventIdentifier: identifier, before: before)
                }
                proposal.targetDestinationID = calendarID; proposal.targetCalendarName = calendarName
                onTargetDestination(calendarID)
                var retained = coordinator.proposals
                for index in retained.indices where !retained[index].isFinished { retained[index].isSelected = false }
                coordinator.replace(with: retained + [proposal])
                try coordinator.persist?(coordinator.proposals)
                return await awaitApproval(name: name, ids: [proposal.id])
            default: throw CalendarToolArgumentError("Unknown calendar tool.")
            }
        } catch { return JSONValue.object(["error": .string(error.localizedDescription)]).jsonString() }
    }

    private var extraSkipped: [CalendarActionProposal] = []
    private func awaitApproval(name: String, ids: Set<UUID>, extraSkipped: [CalendarActionProposal] = []) async -> String {
        guard approvalContinuation == nil else { return #"{"error":"Another approval is waiting."}"# }
        coordinator.approvalScope = ids
        requestIDs = ids; writeTool = name; self.extraSkipped = extraSkipped
        onStep("Waiting for approval")
        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            onApproval(true)
        }
    }

    func finishApproval(_ proposals: [CalendarActionProposal]) {
        guard let continuation = approvalContinuation else { return }
        let relevant = proposals.filter { requestIDs.contains($0.id) }
        let result: JSONValue
        if writeTool == "move_events" {
            result = .object([
                "moved": .array(relevant.filter { $0.state == .moved }.map { .object(["eventIdentifier": .string($0.receipt?.eventIdentifier ?? ""), "sourceEventIdentifier": .string($0.targetEventIdentifier ?? "")]) }),
                "failed": .array(relevant.filter { $0.state == .failed }.map { .object(["proposalID": .string($0.id.uuidString), "sourceEventIdentifier": .string($0.targetEventIdentifier ?? ""), "destinationEventIdentifier": $0.moveCopyReceipt.map { .string($0.eventIdentifier) } ?? .null, "error": .string($0.error ?? "Transfer failed; check both calendars.")]) }),
                "skipped": .array(relevant.filter { !$0.isFinished && $0.state != .failed }.map(Self.skippedJSON))])
        } else if writeTool == "create_events" || writeTool == "create_tasks" {
            result = .object([
                "added": .array(relevant.filter { $0.state == .added }.map { item in
                    .object(["proposalID": .string(item.id.uuidString), "eventIdentifier": .string(item.receipt?.eventIdentifier ?? "")])
                }),
                "failed": .array(relevant.filter { $0.state == .failed }.map { item in
                    .object(["proposalID": .string(item.id.uuidString), "title": .string(item.draft.title), "error": .string(item.error ?? "Calendar write failed.")])
                }),
                "skipped": .array((relevant.filter { !$0.isFinished && $0.state != .failed } + extraSkipped).map(Self.skippedJSON))
            ])
        } else if let item = relevant.first {
            if item.state == .updated { result = .object(["updated": .bool(true), "eventIdentifier": .string(item.receipt?.eventIdentifier ?? "")]) }
            else if item.state == .deleted { result = .object(["deleted": .bool(true)]) }
            else if item.state == .failed { result = .object(["error": .string(item.error ?? "Calendar write failed.")]) }
            else { result = .object(["skipped": .bool(true)]) }
        } else { result = .object(["skipped": .bool(true)]) }
        if writeTool == "delete_event", let item = relevant.first, !item.isFinished, let identifier = item.targetEventIdentifier { cancelledTargets.insert(identifier) }
        for item in relevant where !item.isFinished && item.state != .failed { coordinator.update(item.id) { $0.isSelected = false } }
        coordinator.approvalScope = nil
        approvalContinuation = nil; requestIDs = []; writeTool = nil; extraSkipped = []
        onApproval(false)
        finishTaskImport?()
        continuation.resume(returning: result.jsonString())
    }

    func skipApproval() {
        guard !coordinator.isExecuting else { coordinator.requestStop(); return }
        for id in requestIDs { coordinator.update(id) { $0.isSelected = false } }
        finishApproval(coordinator.proposals)
    }

    func answerQuestion(_ answer: String?) {
        guard let continuation = questionContinuation else { return }
        questionContinuation = nil
        onQuestion(nil)
        if let answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let value = String(answer.prefix(4000))
            confirmedAnswers.append(value)
            ambiguousTargets = []
            continuation.resume(returning: JSONValue.object(["answer": .string(value)]).jsonString())
        } else {
            cancelledTargets.formUnion(ambiguousTargets)
            ambiguousTargets = []
            continuation.resume(returning: #"{"cancelled":true}"#)
        }
    }

    func cancelPending(sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        answerQuestion(nil)
        if coordinator.isExecuting { coordinator.requestStop() }
        else { skipApproval() }
        // Keep in-flight writes alive until their true receipts reach the continuation.
    }

    private func currentDestination() throws -> (id: String, name: String) {
        guard let calendar = destination(), !calendar.id.isEmpty else { throw CalendarToolArgumentError("Choose a writable calendar first.") }
        return calendar
    }
    private func resolveDestination(_ fields: [String: JSONValue], required: Bool = false) throws -> (id: String, name: String) {
        guard let id = try CalendarToolDraftMapper.string(fields, "calendarIdentifier", required: required, limit: 2000) else { return try currentDestination() }
        guard let calendar = searchDestinations?().first(where: { $0.id == id }), !calendar.isReadOnly else {
            throw CalendarToolArgumentError("Choose a connected writable destination by its calendar identifier.")
        }
        return (calendar.id, calendar.title)
    }
    private static func skippedJSON(_ item: CalendarActionProposal) -> JSONValue {
        .object(["proposalID": .string(item.id.uuidString), "title": .string(item.draft.title)])
    }
    static func occurrenceKey(_ event: CalendarEventSnapshot) -> String {
        (event.externalEventIdentifier ?? event.eventIdentifier) + "|" + String(event.start.timeIntervalSince1970) + "|" + String(event.end.timeIntervalSince1970)
    }
    private static func eventJSON(_ event: CalendarEventSnapshot) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        return .object(["eventIdentifier": .string(event.eventIdentifier), "title": .string(event.title),
            "start": .string(formatter.string(from: event.start)), "end": .string(formatter.string(from: event.end)),
            "isAllDay": .bool(event.isAllDay), "isFree": event.isFree.map(JSONValue.bool) ?? .null, "timeZone": event.timeZone.map(JSONValue.string) ?? .null,
            "location": event.location.map(JSONValue.string) ?? .null, "calendarName": .string(event.calendarName)])
    }
}
