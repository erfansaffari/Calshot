import Foundation
import CryptoKit

/// "What Calshot did": saved calendar changes from receipts, newest first, each with Undo.
/// Clicking Undo is the user's explicit request for that one reverse change. It is built natively from the
/// receipt and the event as it is now, never replays the original write, and is recorded with `undoOf`.
@MainActor
extension CalshotModel {
    static let recentChangeLimit = 8

    var recentChangesToken: String { recentChangesToken(calendarChangeLedger()) }

    private func recentChangesToken(_ all: [CalendarActionProposal]) -> String {
        let ledger = all.prefix(40)
        let undone = Set(ledger.compactMap(\.undoOf))
        let text = ledger.map { $0.id.uuidString + (undone.contains($0.id) ? "u" : "") }.joined(separator: "|") + "|" + (account.userID?.uuidString ?? "")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func recentChangesSnapshot(now: Date = Date()) -> JSONValue {
        let ledger = calendarChangeLedger()
        let undone = Set(ledger.compactMap(\.undoOf))
        let iso = WebWorkspaceState.iso
        let rows: [JSONValue] = ledger.prefix(Self.recentChangeLimit).map { change in
            let isUndo = change.undoOf != nil
            let canUndo = !isUndo && !undone.contains(change.id) && !(change.operation == .delete && change.targetOccurrence?.isRecurring == true)
            var fields: [String: JSONValue] = [
                "id": .string(change.id.uuidString), "operation": .string(change.operation.rawValue), "title": .string(change.draft.title),
                "calendar": .string(change.receipt?.calendarName ?? change.targetCalendarName ?? ""),
                "start": change.draft.startDate.map { .string(iso.string(from: $0)) } ?? .null,
                "end": change.draft.endDate.map { .string(iso.string(from: $0)) } ?? .null,
                "allDay": .bool(change.draft.isAllDay),
                "savedAt": change.receipt.map { .string(iso.string(from: $0.savedAt)) } ?? .null,
                "isUndo": .bool(isUndo), "undone": .bool(undone.contains(change.id)), "canUndo": .bool(canUndo),
                "undoing": .bool(undoingChangeIDs.contains(change.id)),
                "error": undoErrors[change.id].map(JSONValue.string) ?? .null]
            if change.operation == .move { fields["fromCalendar"] = .string(change.sourceCalendarName ?? "") }
            if change.operation == .update, let before = change.before {
                fields["previousTitle"] = .string(before.title)
                fields["previousStart"] = before.startDate.map { .string(iso.string(from: $0)) } ?? .null
            }
            return .object(fields)
        }
        return .object(["items": .array(rows), "token": .string(recentChangesToken(ledger))])
    }

    /// Reverses one saved change the user clicked Undo on. Guests and repeating events are not undone here,
    /// because changing them notifies other people or affects more than one occurrence.
    func undoCalendarChange(_ id: UUID, token: String) async throws {
        guard token == recentChangesToken else { throw CalendarToolArgumentError("Your recent changes were updated. Check the list and try again.") }
        guard !isSaving, !agentIsWaitingForApproval, agentTaskReview == nil, !calendarActions.isExecuting, !directCalendarWriter.isWriting, undoingChangeIDs.isEmpty else {
            throw CalendarToolArgumentError("Finish the current review or save first.")
        }
        let ledger = calendarChangeLedger()
        guard let change = ledger.first(where: { $0.id == id }), change.undoOf == nil, change.receipt != nil else { throw CalendarToolArgumentError("That change isn’t in your saved history.") }
        guard !ledger.contains(where: { $0.undoOf == id }) else { throw CalendarToolArgumentError("Already undone.") }
        if agentToolExecutor == nil { configureCalendarAgent() }
        guard let executor = agentToolExecutor, let main = mainChatID() else { throw CalendarToolArgumentError("Your saved changes couldn’t be opened.") }
        undoingChangeIDs.insert(id); undoErrors[id] = nil
        defer { undoingChangeIDs.remove(id) }
        let owner = account.userID
        do {
            let (row, destinationID, destinationName) = try await executor.reversal(of: change)
            guard !row.guests, row.recurring != true else {
                throw CalendarToolArgumentError("This event has guests or repeats, so undo it in Calendar or ask Calshot to change it.")
            }
            guard account.userID == owner else { throw CancellationError() }
            var result = try await directCalendarWriter.apply(row.proposal, destinationID: destinationID, calendarName: destinationName)
            result.targetDestinationID = destinationID; result.targetCalendarName = destinationName
            // The reverse change is saved; record it so the original shows as undone and is never undone twice.
            _ = try memoryStore.mergeProposals(for: main, proposals: [result])
            refreshMemory()
            executor.invalidateCalendarCache()
        } catch is CancellationError {
            throw CalendarToolArgumentError("The account changed before this was undone.")
        } catch {
            undoErrors[id] = error.localizedDescription
            throw error
        }
    }
}
