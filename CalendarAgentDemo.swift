#if DEBUG
import Foundation

/// Scripted model for the isolated native agent demo. Never contacts an AI provider.
@MainActor
final class CalendarAgentDemoClient: CalendarAgentModelClient {
    func turn(conversation: [AgentMessage], imageDataURL: String?, instructions: String,
              tools: [JSONValue], onText: @escaping @MainActor (String) -> Void) async throws -> AgentModelResponse {
        try Task.checkCancellation()
        let content = conversation.first?.value.objectValue?["content"]
        let command = (content?.stringValue ?? content?.arrayValue?.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n") ?? "").lowercased()
        let results = toolResults(in: conversation)
        if command.contains("question layout") {
            if results["ask_user"] != nil { return finish("Answer received. This layout test did not change any calendars.", onText: onText) }
            return call("ask_user", arguments: .object([
                "question": .string("Both shifts are now on Work, and the originals are still on Personal. Which originals should I remove?"),
                "choices": .array([.string("Remove both Apple Calendar originals"), .string("Remove only the October 20 original"), .string("Remove only the October 22 original"), .string("Keep both Apple Calendar originals")])]))
        }
        if command.contains("delete") || command.contains("remove") || command.contains("move") || command.contains("update") {
            return changeTurn(command: command, results: results, onText: onText)
        }
        if let receipt = results["create_events"] { return finish(receiptSummary(receipt), onText: onText) }
        if let answer = results["ask_user"] {
            if answer.objectValue?["cancelled"]?.boolValue == true {
                return finish("Cancelled the question. No calendar events were changed.", onText: onText)
            }
            let allDay = answer.objectValue?["answer"]?.stringValue?.lowercased().contains("all-day") == true
            return call("create_events", arguments: .object(["events": .array([
                draft(title: "Assignment 1", date: "2026-10-16", start: nil, end: nil, allDay: allDay),
                draft(title: "Midterm exam", date: "2026-11-06", start: "10:00", end: "11:30", allDay: false)
            ])]))
        }
        onText("I found an assignment deadline and a midterm in the demo syllabus.")
        return call("ask_user", arguments: .object([
            "question": .string("The assignment has a date but no time. Use an all-day deadline?"),
            "choices": .array([.string("Use all-day"), .string("Let me choose a time")])
        ]))
    }

    private func changeTurn(command: String, results: [String: JSONValue], onText: @escaping @MainActor (String) -> Void) -> AgentModelResponse {
        let deleting = command.contains("delete") || command.contains("remove")
        let operation = deleting ? "delete_event" : "update_event"
        if let result = results[operation] {
            if result.objectValue?["skipped"]?.boolValue == true { return finish("Skipped the proposed change. The event was left untouched.", onText: onText) }
            if let error = result.objectValue?["error"]?.stringValue { return finish("The change did not complete: \(error)", onText: onText) }
            let succeeded = result.objectValue?[deleting ? "deleted" : "updated"]?.boolValue == true
            return finish(succeeded ? (deleting ? "Removed 1 event from the demo calendar." : "Updated 1 event in the demo calendar.") : "No successful write was reported.", onText: onText)
        }
        if let search = results["search_events"] {
            let events = search.arrayValue ?? search.objectValue?["events"]?.arrayValue ?? []
            guard let event = events.first?.objectValue, let identifier = event["eventIdentifier"]?.stringValue else {
                return finish("No saved demo midterm was found. Approve the demo syllabus first, then try this command again.", onText: onText)
            }
            if deleting {
                return call(operation, arguments: .object(["eventIdentifier": .string(identifier), "reason": .string("You asked to remove the saved demo midterm.")]))
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let raw = event["start"]?.stringValue ?? ""
            let start = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) ?? Date()
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            let dateFormatter = DateFormatter()
            dateFormatter.calendar = calendar; dateFormatter.timeZone = calendar.timeZone; dateFormatter.dateFormat = "yyyy-MM-dd"
            return call(operation, arguments: .object(["eventIdentifier": .string(identifier), "date": .string(dateFormatter.string(from: tomorrow))]))
        }
        onText("I'll search the demo calendar before proposing a change.")
        return call("search_events", arguments: .object(["query": .string("Midterm exam"), "start": .null, "end": .null]))
    }

    private func draft(title: String, date: String, start: String?, end: String?, allDay: Bool) -> JSONValue {
        .object(["title": .string(title), "date": .string(date), "startTime": start.map(JSONValue.string) ?? .null,
                 "endTime": end.map(JSONValue.string) ?? .null, "allDay": .bool(allDay),
                 "timeZone": .string(TimeZone.current.identifier), "location": .null, "url": .null,
                 "notes": .string("Offline agent demo; writes stay in the isolated demo calendar."),
                 "evidence": .string(title == "Assignment 1" ? "Assignment 1 | October 16, 2026" : "Midterm exam | November 6, 2026 | 10:00 AM - 11:30 AM"),
                 "yearInferred": .bool(false), "dateAmbiguous": .bool(false)])
    }

    private func call(_ name: String, arguments: JSONValue) -> AgentModelResponse {
        .init(calls: [.init(name: name, callID: UUID().uuidString, arguments: arguments.jsonString())])
    }
    private func finish(_ text: String, onText: @escaping @MainActor (String) -> Void) -> AgentModelResponse {
        onText(text)
        return .init(output: [.text(role: "assistant", content: text)], text: text)
    }
    private func receiptSummary(_ result: JSONValue) -> String {
        let receipt = result.objectValue ?? [:]
        let added = receipt["added"]?.arrayValue?.count ?? 0
        let failed = receipt["failed"]?.arrayValue?.count ?? 0
        let skipped = receipt["skipped"]?.arrayValue?.count ?? 0
        return "Demo complete: added \(added), failed \(failed), skipped \(skipped). Only reported approval receipts are counted."
    }
    private func toolResults(in conversation: [AgentMessage]) -> [String: JSONValue] {
        var names: [String: String] = [:]
        var results: [String: JSONValue] = [:]
        for message in conversation {
            guard let value = message.value.objectValue, let id = value["call_id"]?.stringValue else { continue }
            if let name = value["name"]?.stringValue { names[id] = name }
            if let output = value["output"]?.stringValue, let name = names[id],
               let result = try? JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)) { results[name] = result }
        }
        return results
    }
}
#endif
