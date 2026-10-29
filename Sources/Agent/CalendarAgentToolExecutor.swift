import Foundation

struct AgentQuestion: Identifiable {
    let id = UUID()
    let question: String
    let choices: [String]
}

@MainActor
final class CalendarAgentToolExecutor: CalendarAgentToolExecuting {
    var remember: ((MemoryItem.Kind, String) throws -> Void)?
    var recall: ((String) throws -> String)?
    var memorySuggestionsBlocked = false
    var taskImportReceipts: ((JSONValue) -> JSONValue)?
    var finishTaskImport: (() -> Void)?
    var listTasks: (() throws -> JSONValue)?
    var selectedTaskContext: ((UUID) throws -> JSONValue)?
    /// Pure preflight; must never save a task or invoke a provider write.
    var prepareTaskMutation: ((AgentPreparedTaskMutation, UUID) async throws -> JSONValue)?
    /// Native approval/policy integration owns authorization, fresh preflight and domain execution.
    /// Chat text and model-supplied identifiers are never an authorization decision.
    var authorizeTaskMutation: ((AgentPreparedTaskMutation, UUID) async throws -> JSONValue)?
    /// Resume/cancel native pending task review; preserve receipts for already-dispatched writes.
    var cancelTaskMutation: ((UUID) -> Void)?
    /// Task-only creation under a saved explicit grant. Returns nil when the user must review the import
    /// (no matching grant or a dated deadline needs its own calendar review). Never approves calendar writes.
    var commitTaskOnlyImport: ((UUID) async throws -> JSONValue?)?
    var availableToolNames: Set<String> {
        var names = CalendarAgent.toolNames
        if remember == nil { names.remove("remember") }; if recall == nil { names.remove("recall") }
        if listTasks == nil { names.subtract(["list_tasks", "get_tasks"]) }
        if selectedTaskContext == nil { names.remove("get_selected_event_context") }
        if prepareTaskMutation == nil || authorizeTaskMutation == nil {
            names.subtract(["link_event_to_task", "update_tasks", "set_task_completion", "set_task_archived"])
        }
        return names
    }
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
    private var sessionCancelled = false
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
        self.sessionID = sessionID; sessionCancelled = false
        memorySuggestionsBlocked = false
        searched = [:]; ambiguousTargets = []; cancelledTargets = []; confirmedAnswers = []
    }

    func execute(name: String, arguments: JSONValue, sessionID: UUID) async -> String {
        guard self.sessionID == sessionID, !sessionCancelled, !Task.isCancelled else { return #"{"cancelled":true}"# }
        do {
            guard let fields = arguments.objectValue else { throw CalendarToolArgumentError("Arguments must be an object.") }
            switch name {
            case "remember":
                try CalendarToolDraftMapper.keys(fields, allowed: ["kind", "text"])
                guard !memorySuggestionsBlocked, let remember else { throw CalendarToolArgumentError("Memory suggestions are unavailable in a conversation with shared-friend calendar context.") }
                guard let raw = try CalendarToolDraftMapper.string(fields, "kind", required: true, limit: 20), let kind = MemoryItem.Kind(rawValue: raw),
                      let text = try CalendarToolDraftMapper.string(fields, "text", required: true, limit: 500), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CalendarToolArgumentError("Choose a valid memory kind and text.") }
                try remember(kind, text)
                return JSONValue.object(["status": .string("pendingApproval"), "message": .string("Suggested memory awaits your approval in Settings → Privacy & permissions → Memory.")]).jsonString()
            case "recall":
                try CalendarToolDraftMapper.keys(fields, allowed: ["query"])
                guard let recall, let query = try CalendarToolDraftMapper.string(fields, "query", required: true, limit: 500), !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CalendarToolArgumentError("Provide a query of 1–500 characters.") }
                return JSONValue.object(["context": .string(try recall(query))]).jsonString()
            case "list_tasks":
                try CalendarToolDraftMapper.keys(fields, allowed: ["includeArchived"])
                if let flag = fields["includeArchived"], flag != .null, flag.boolValue == nil { throw CalendarToolArgumentError("includeArchived must be a boolean.") }
                let rows = try currentTasks()
                return JSONValue.object(["tasks": .array(rows.filter { fields["includeArchived"] == .bool(true) || $0.objectValue?["archived"] != .bool(true) })]).jsonString()
            case "get_tasks":
                try CalendarToolDraftMapper.keys(fields, allowed: ["taskIDs"])
                guard let ids = fields["taskIDs"]?.arrayValue, !ids.isEmpty, ids.count <= 100 else { throw CalendarToolArgumentError("Provide 1–100 task IDs.") }
                let requested = try ids.map { value -> UUID in
                    guard let id = value.stringValue.flatMap(UUID.init(uuidString:)) else { throw CalendarToolArgumentError("Use task IDs returned by a current task read.") }
                    return id
                }
                guard Set(requested).count == requested.count else { throw CalendarToolArgumentError("Each task must occur once.") }
                let rows = try currentTasks()
                return JSONValue.object(["tasks": .array(rows.filter { row in row.objectValue?["id"]?.stringValue.flatMap(UUID.init(uuidString:)).map { requested.contains($0) } ?? false }),
                    "missingTaskIDs": .array(requested.filter { id in !rows.contains { $0.objectValue?["id"]?.stringValue.flatMap(UUID.init(uuidString:)) == id } }.map { .string($0.uuidString) })]).jsonString()
            case "get_selected_event_context":
                try CalendarToolDraftMapper.keys(fields, allowed: [])
                guard let selectedTaskContext else { throw CalendarToolArgumentError("No selected event context is available.") }
                return try selectedTaskContext(sessionID).jsonString()
            case "link_event_to_task", "update_tasks", "set_task_completion", "set_task_archived":
                let prepared = try prepareTaskMutationArguments(name: name, fields: fields)
                guard let prepareTaskMutation, let authorizeTaskMutation else {
                    return JSONValue.object(["status": .string("needsAuthorization"), "saved": .bool(false), "error": .string("Conversation task changes are unavailable until native task authorization is connected. Use the task or selected-event controls.")]).jsonString()
                }
                _ = try await prepareTaskMutation(prepared, sessionID)
                guard self.sessionID == sessionID, !sessionCancelled, !Task.isCancelled else { return #"{"cancelled":true}"# }
                let result = try await authorizeTaskMutation(prepared, sessionID)
                // A dispatched operation may complete after Stop; the native hook must return its
                // actual receipts. A replacement session must never receive those old results.
                guard self.sessionID == sessionID else { return #"{"cancelled":true}"# }
                return result.jsonString()
            case "create_tasks":
                guard let createTasks else { throw CalendarToolArgumentError("Tasks are unavailable.") }
                let result = try createTasks(fields)
                let hasNew = result.saved.arrayValue?.contains { $0.objectValue?["alreadyInTasks"] != .bool(true) } == true
                guard hasNew else { return JSONValue.object(["tasksSaved": taskImportReceipts?(result.saved) ?? .array([]), "calendar": .string("Already in Tasks. No new calendar writes.")]).jsonString() }
                if result.proposals.isEmpty, let commitTaskOnlyImport {
                    // Task-only: a matching saved grant saves immediately; otherwise fall through to the existing review.
                    if let committed = try await commitTaskOnlyImport(sessionID) {
                        guard self.sessionID == sessionID else { return #"{"cancelled":true}"# }
                        finishTaskImport?()
                        return JSONValue.object(["tasksSaved": committed, "calendar": .string("No calendar changes. This was task-only.")]).jsonString()
                    }
                    guard self.sessionID == sessionID, !sessionCancelled, !Task.isCancelled else { return #"{"cancelled":true}"# }
                }
                coordinator.replace(with: coordinator.proposals + result.proposals)
                try coordinator.persist?(coordinator.proposals)
                let calendar = await awaitApproval(name: name, ids: Set(result.proposals.map(\.id)))
                return JSONValue.object(["tasksSaved": taskImportReceipts?(result.saved) ?? .array([]), "calendar": (try? JSONDecoder().decode(JSONValue.self, from: Data(calendar.utf8))) ?? .string(calendar)]).jsonString()
            case "list_friends":
                memorySuggestionsBlocked = true
                try CalendarToolDraftMapper.keys(fields, allowed: [])
                guard let listFriends else { throw CalendarToolArgumentError("Friend sharing is unavailable. Open Friends & sharing in Settings.") }
                onStep("Checking friends who share with you")
                let result = try await listFriends()
                guard self.sessionID == sessionID, !sessionCancelled, !Task.isCancelled else { return #"{"cancelled":true}"# }
                return result.jsonString()
            case "search_friend_events":
                memorySuggestionsBlocked = true
                try CalendarToolDraftMapper.keys(fields, allowed: ["friendID", "query", "start", "end"])
                guard let id = try CalendarToolDraftMapper.string(fields, "friendID", required: true, limit: 36), UUID(uuidString: id) != nil,
                      let start = try CalendarToolDraftMapper.instant(fields, "start"), let end = try CalendarToolDraftMapper.instant(fields, "end"),
                      end > start, end.timeIntervalSince(start) <= 63 * 86400 else { throw CalendarToolArgumentError("Choose a listed friend and explicit dates covering up to 63 days.") }
                _ = try CalendarToolDraftMapper.string(fields, "query", limit: 200)
                guard let searchFriend else { throw CalendarToolArgumentError("Friend calendar reads are unavailable.") }
                onStep("Checking your friend’s shared calendars")
                let result = try await searchFriend(fields)
                guard self.sessionID == sessionID, !sessionCancelled, !Task.isCancelled else { return #"{"cancelled":true}"# }
                // Friend event IDs never enter the searched targets used by write tools.
                return result.jsonString()
            case "read_screen_text":
                try CalendarToolDraftMapper.keys(fields, allowed: [])
                let text = await screenText()
                guard self.sessionID == sessionID, !sessionCancelled, !Task.isCancelled else { return #"{"cancelled":true}"# }
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
                        guard self.sessionID == sessionID, !sessionCancelled, !Task.isCancelled else { return #"{"cancelled":true}"# }
                        events.append(contentsOf: found.map { ($0, calendar.id) })
                        results.append(.object(["id": .string(calendar.id), "name": .string(calendar.title), "sourceName": .string(calendar.sourceName ?? calendar.provider.rawValue), "isReadOnly": .bool(calendar.isReadOnly), "count": .number(Double(found.count))]))
                    } catch {
                        guard self.sessionID == sessionID, !sessionCancelled, !Task.isCancelled else { return #"{"cancelled":true}"# }
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
                guard self.sessionID == sessionID, !sessionCancelled, !Task.isCancelled else { return #"{"cancelled":true}"# }
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
                    guard self.sessionID == sessionID, !sessionCancelled, !Task.isCancelled else { return #"{"cancelled":true}"# }
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
                guard self.sessionID == sessionID, !sessionCancelled, !Task.isCancelled else { return #"{"cancelled":true}"# }
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
                guard self.sessionID == sessionID, !sessionCancelled, !Task.isCancelled else { return #"{"cancelled":true}"# }
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
        } catch is CancellationError { return #"{"cancelled":true}"# }
        catch { return JSONValue.object(["error": .string(error.localizedDescription)]).jsonString() }
    }

    private func currentTasks() throws -> [JSONValue] {
        guard let listTasks, let rows = try listTasks().arrayValue else { throw CalendarToolArgumentError("Tasks are unavailable. Reload Tasks and try again.") }
        return rows
    }

    /// Validation is shared by the exposed tools and future native review integration.
    func prepareTaskMutationArguments(name: String, fields: [String: JSONValue]) throws -> AgentPreparedTaskMutation {
        if name == "link_event_to_task" {
            try CalendarToolDraftMapper.keys(fields, allowed: ["contextReference"])
            guard let reference = try CalendarToolDraftMapper.string(fields, "contextReference", required: true, limit: 36).flatMap(UUID.init(uuidString:)) else { throw CalendarToolArgumentError("Use the current native selected context reference.") }
            return AgentPreparedTaskMutation(id: UUID(), change: .linkSelectedEvent(contextReference: reference))
        }
        guard ["update_tasks", "set_task_completion", "set_task_archived"].contains(name) else { throw CalendarToolArgumentError("Unknown task mutation.") }
        try CalendarToolDraftMapper.keys(fields, allowed: ["tasks"])
        guard let rows = fields["tasks"]?.arrayValue, !rows.isEmpty, rows.count <= 100 else { throw CalendarToolArgumentError("Provide 1–100 task changes.") }
        let allowed: Set<String> = name == "set_task_completion" ? ["completed"] : name == "set_task_archived" ? ["archived"] : ["title", "dueDate", "dueTime", "timeZone", "notes"]
        var seen = Set<UUID>()
        let patches = try rows.map { row -> AgentPreparedTaskMutation.Patch in
            guard let values = row.objectValue else { throw CalendarToolArgumentError("Each task change must be an object.") }
            try CalendarToolDraftMapper.keys(values, allowed: ["taskID", "expectedVersion", "patch"])
            guard let id = try CalendarToolDraftMapper.string(values, "taskID", required: true, limit: 36).flatMap(UUID.init(uuidString:)),
                  let version = try CalendarToolDraftMapper.string(values, "expectedVersion", required: true, limit: 36).flatMap(UUID.init(uuidString:)),
                  seen.insert(id).inserted, let patch = values["patch"]?.objectValue, !patch.isEmpty else { throw CalendarToolArgumentError("Use unique task IDs, exact current versions and a nonempty patch.") }
            try CalendarToolDraftMapper.keys(patch, allowed: allowed)
            for (key, value) in patch {
                if key == "completed" || key == "archived" {
                    guard value.boolValue != nil else { throw CalendarToolArgumentError("Task state must be a boolean.") }
                } else {
                    let nullable = ["dueDate", "dueTime", "notes"].contains(key)
                    let limit = key == "notes" ? 8000 : key == "title" ? 500 : key == "timeZone" ? 100 : key == "dueDate" ? 10 : 5
                    let text = try CalendarToolDraftMapper.string(patch, key, required: !nullable, limit: limit)
                    if let text {
                        if key == "dueDate", text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil {
                            throw CalendarToolArgumentError("A task date needs an explicit year in YYYY-MM-DD form. Leave missing dates unresolved.")
                        }
                        if key == "dueTime", text.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) == nil { throw CalendarToolArgumentError("Use HH:mm for a task time.") }
                        if key == "timeZone", TimeZone(identifier: text) == nil { throw CalendarToolArgumentError("Use a valid task timezone.") }
                        if key == "title", text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw CalendarToolArgumentError("A task title is required.") }
                    }
                    guard value != .null || nullable else { throw CalendarToolArgumentError("This task field cannot be cleared.") }
                }
            }
            return .init(operationID: UUID(), taskID: id, expectedVersion: version, fields: patch)
        }
        return AgentPreparedTaskMutation(id: UUID(), change: .patches(patches))
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
        sessionCancelled = true
        cancelTaskMutation?(sessionID)
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
