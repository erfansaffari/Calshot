import XCTest
@testable import Calshot

final class AgentPermissionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("permission-tests-" + UUID().uuidString)
    }
    private func operation(id: UUID = UUID(), run: UUID = UUID(), action: AgentPermissionAction = .taskCreate,
                           count: Int = 1, calendar: Set<String> = [], fields: Set<String> = ["title"],
                           owner: String = "fictional-owner", device: String = "fictional-device",
                           effect: String = "Fictional task", guests: Bool = false, series: Bool = false,
                           sharing: Bool = false) -> AgentPermissionOperation {
        let ids = Set((0..<count).map { "\(id)-\($0)" })
        let create = action == .taskCreate || action == .calendarCreate
        return AgentPermissionOperation(operationID: id, runID: run, ownerID: owner, deviceID: device,
            action: action, resourceIDs: ids, expectedVersions: create ? [:] : Dictionary(uniqueKeysWithValues: ids.map { ($0, "v1") }),
            calendarIDs: calendar, fields: fields, effectDigest: AgentPermissionOperation.hash(Data(effect.utf8)),
            hasGuestEffects: guests, affectsSeries: series, hasSharingEffects: sharing)
    }
    private func resources(_ operation: AgentPermissionOperation, owner: String = "fictional-owner",
                           device: String = "fictional-device", cancelled: Bool = false,
                           calendars: Set<String> = ["fictional-calendar"]) -> AgentPermissionResources {
        AgentPermissionResources(ownerID: owner, deviceID: device, versions: operation.expectedVersions,
            writableCalendarIDs: calendars, supportedActions: Set(AgentPermissionAction.allCases), cancelled: cancelled)
    }
    private func store(_ directory: URL, ttl: TimeInterval = 300) throws -> AgentPermissionStore {
        let date = now
        return try AgentPermissionStore(directory: directory, ownerID: "fictional-owner", deviceID: "fictional-device",
                                        reservationTTL: ttl, clock: { date })
    }
    private func grant(_ action: AgentPermissionAction = .taskCreate, background: Bool = false,
                       calendar: Set<String> = [], fields: Set<String> = ["title"], expires: Date? = nil) -> AgentPermissionGrant {
        AgentPermissionGrant(action: action, requestedEnabled: true, backgroundEnabled: background,
            calendarIDs: calendar, fields: fields, expiresAt: expires ?? now.addingTimeInterval(3600))
    }
    private func configure(_ store: AgentPermissionStore, grants: [AgentPermissionGrant]? = nil,
                           limit: Int = 20, window: Int = 100, revision: UInt64 = 0) async throws {
        try await store.replaceGrants(grants ?? [grant()], expectedRevision: revision,
            control: AgentPermissionSettingsControl(nativeOwnerID: "fictional-owner", nativeDeviceID: "fictional-device"),
            maxPerRun: limit, maxPerWindow: window)
    }
    private func allowed(_ decision: AgentPermissionDecision, file: StaticString = #filePath, line: UInt = #line) throws -> AgentPermissionEnvelope {
        guard case .allow(let envelope) = decision else {
            XCTFail("Expected allow; got \(decision)", file: file, line: line)
            throw AgentPermissionError.invalidEnvelope
        }
        return envelope
    }
    private func isReview(_ decision: AgentPermissionDecision, file: StaticString = #filePath, line: UInt = #line) {
        guard case .requireReview = decision else { XCTFail("Expected review; got \(decision)", file: file, line: line); return }
    }
    private func isDenied(_ decision: AgentPermissionDecision, file: StaticString = #filePath, line: UInt = #line) {
        guard case .deny = decision else { XCTFail("Expected deny; got \(decision)", file: file, line: line); return }
    }

    func testDefaultAndBackgroundHaveNoAuthority() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir), op = operation()
        isReview(try await store.reserve(op, context: .userRequested(), resources: resources(op)))
        try await configure(store)
        isReview(try await store.reserve(op, context: .background(), resources: resources(op)))
        _ = try allowed(await store.reserve(op, context: .userRequested(), resources: resources(op)))
        let other = operation()
        try await configure(store, grants: [grant(background: true)], revision: 1)
        _ = try allowed(await store.reserve(other, context: .background(), resources: resources(other)))
    }

    func testOwnerDeviceAndCurrentResourcesAreAuthoritative() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir); try await configure(store)
        for op in [operation(owner: "other"), operation(device: "other")] {
            isDenied(try await store.reserve(op, context: .userRequested(), resources: resources(op)))
        }
        let op = operation()
        isDenied(try await store.reserve(op, context: .userRequested(), resources: resources(op, owner: "other")))
        isDenied(try await store.reserve(op, context: .userRequested(), resources: resources(op, device: "other")))
        isDenied(try await store.reserve(op, context: .userRequested(), resources: resources(op, cancelled: true)))
    }

    func testExactTaskSubmissionCannotAuthorizeExtrasOrCalendar() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir), shown = operation()
        _ = try allowed(await store.reserve(shown, context: .directTaskSubmission(shown), resources: resources(shown)))
        let extra = operation(effect: "Extra effect")
        isReview(try await store.reserve(extra, context: .directTaskSubmission(shown), resources: resources(extra)))
        let calendar = operation(action: .calendarCreate, calendar: ["fictional-calendar"])
        isReview(try await store.reserve(calendar, context: .directTaskSubmission(calendar), resources: resources(calendar)))
    }

    func testGrantedDeleteAndMoveOfOneEventAllowButGuestsSeriesAndBatchesAsk() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir)
        try await configure(store, grants: [grant(.calendarDelete, calendar: ["fictional-calendar"], fields: ["delete"]),
                                            grant(.calendarMove, calendar: ["fictional-calendar", "other-calendar"], fields: ["destination"])])
        let delete = operation(action: .calendarDelete, calendar: ["fictional-calendar"], fields: ["delete"])
        _ = try allowed(await store.reserve(delete, context: .userRequested(), resources: resources(delete)))
        let move = operation(action: .calendarMove, calendar: ["fictional-calendar", "other-calendar"], fields: ["destination"])
        _ = try allowed(await store.reserve(move, context: .userRequested(), resources: resources(move, calendars: ["fictional-calendar", "other-calendar"])))
        for risky in [operation(action: .calendarDelete, calendar: ["fictional-calendar"], fields: ["delete"], guests: true),
                      operation(action: .calendarDelete, calendar: ["fictional-calendar"], fields: ["delete"], series: true),
                      operation(action: .calendarDelete, count: 2, calendar: ["fictional-calendar"], fields: ["delete"])] {
            isReview(try await store.reserve(risky, context: .userRequested(), resources: resources(risky)))
        }
        let background = operation(action: .calendarDelete, calendar: ["fictional-calendar"], fields: ["delete"])
        isReview(try await store.reserve(background, context: .background(), resources: resources(background)))
    }

    func testCalendarScopeFieldsAndDangerousEffects() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir)
        try await configure(store, grants: [grant(.calendarCreate, calendar: ["fictional-calendar"])])
        let normal = operation(action: .calendarCreate, calendar: ["fictional-calendar"])
        _ = try allowed(await store.reserve(normal, context: .userRequested(), resources: resources(normal)))
        let field = operation(action: .calendarCreate, calendar: ["fictional-calendar"], fields: ["notes"])
        isReview(try await store.reserve(field, context: .userRequested(), resources: resources(field)))
        let other = operation(action: .calendarCreate, calendar: ["other-calendar"])
        isReview(try await store.reserve(other, context: .userRequested(), resources: resources(other, calendars: ["other-calendar"])))
        isDenied(try await store.reserve(other, context: .userRequested(), resources: resources(other)))
        for op in [operation(action: .calendarDelete, calendar: ["fictional-calendar"], fields: ["delete"]),
                   operation(action: .calendarMove, calendar: ["fictional-calendar"], fields: ["destination"]),
                   operation(guests: true), operation(series: true)] {
            isReview(try await store.reserve(op, context: .directTaskSubmission(op), resources: resources(op)))
        }
        let sharing = operation(sharing: true)
        isDenied(try await store.reserve(sharing, context: .directTaskSubmission(sharing), resources: resources(sharing)))
    }

    func testReviewedTaskSubmissionMayExceedQuotasButNeverWidensScopeOrReservesTwice() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir)
        try await configure(store, grants: [])
        let policy = try await store.snapshot()
        let big = operation(action: .taskEdit, count: policy.maxPerRun + 1, fields: ["title"])
        // Quotas bound unattended and exact direct submissions; only an explicit visible review exceeds them.
        isReview(try await store.reserve(big, context: .directTaskSubmission(big), resources: resources(big)))
        let envelope = try allowed(await store.reserve(big, context: .reviewedTaskSubmission(big), resources: resources(big)))
        XCTAssertEqual(envelope.operation, big)
        // The reviewed effect consumes capacity: a later unattended request in the same run still needs review.
        let next = operation(run: big.runID, action: .taskEdit, fields: ["title"])
        isReview(try await store.reserve(next, context: .directTaskSubmission(next), resources: resources(next)))
        // A different (unshown) effect or a calendar action is not covered by a review of something else.
        let other = operation(action: .taskEdit, count: policy.maxPerRun + 1, fields: ["notes"])
        isReview(try await store.reserve(other, context: .reviewedTaskSubmission(big), resources: resources(other)))
        let calendar = operation(action: .calendarCreate, calendar: ["fictional-calendar"])
        isReview(try await store.reserve(calendar, context: .reviewedTaskSubmission(calendar), resources: resources(calendar)))
    }

    func testReviewedSubmissionAboveAnExhaustedWindowStaysRecordedAndBlocksLaterGrantUse() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir)
        try await configure(store, grants: [grant(.taskEdit)], limit: 5, window: 8)
        // Fill the window with saved-grant work, then exceed it through an explicit visible review.
        let first = operation(action: .taskEdit, count: 5)
        let firstEnvelope = try allowed(await store.reserve(first, context: .userRequested(), resources: resources(first)))
        try await store.beginDispatch(firstEnvelope, resources: resources(first)); try await store.settle(firstEnvelope, outcome: .succeeded)
        let overflow = operation(action: .taskEdit, count: 6)
        isReview(try await store.reserve(overflow, context: .userRequested(), resources: resources(overflow)))
        isReview(try await store.reserve(overflow, context: .directTaskSubmission(overflow), resources: resources(overflow)))
        let reviewed = try allowed(await store.reserve(overflow, context: .reviewedTaskSubmission(overflow), resources: resources(overflow)))
        try await store.beginDispatch(reviewed, resources: resources(overflow)); try await store.settle(reviewed, outcome: .succeeded)
        // The window now holds 11 of 8: neither a saved grant nor an exact direct submission may use it.
        let later = operation(action: .taskEdit)
        isReview(try await store.reserve(later, context: .userRequested(), resources: resources(later)))
        isReview(try await store.reserve(later, context: .directTaskSubmission(later), resources: resources(later)))
        // The ledger keeps both effects as evidence, and a repeated reviewed reservation of a settled effect cannot dispatch again.
        let records = try await store.operationRecords()
        XCTAssertEqual(records.filter { $0.status == "succeeded" }.count, 2)
        isDenied(try await store.reserve(overflow, context: .reviewedTaskSubmission(overflow), resources: resources(overflow)))
        do { try await store.beginDispatch(reviewed, resources: resources(overflow)); XCTFail("A settled reviewed effect dispatched twice") } catch {}
    }

    func testRevisionRevocationAndStaleSettingsFenceDispatch() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir), op = operation(); try await configure(store)
        let envelope = try allowed(await store.reserve(op, context: .userRequested(), resources: resources(op)))
        try await configure(store, grants: [], revision: 1)
        do { try await store.beginDispatch(envelope, resources: resources(op)); XCTFail("Revoked dispatch") }
        catch { XCTAssertEqual(error as? AgentPermissionError, .invalidEnvelope) }
        isDenied(try await store.reserve(op, context: .userRequested(), resources: resources(op)))
        do { try await configure(store, revision: 1); XCTFail("Stale settings") }
        catch { XCTAssertEqual(error as? AgentPermissionError, .stalePolicy) }
        do {
            try await store.replaceGrants([], expectedRevision: 2,
                control: AgentPermissionSettingsControl(nativeOwnerID: "other", nativeDeviceID: "fictional-device"))
            XCTFail("Wrong settings owner")
        } catch { XCTAssertEqual(error as? AgentPermissionError, .wrongOwnerOrDevice) }
    }

    func testBulkAndConcurrentOperationsShareCumulativeAllowance() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir); try await configure(store, limit: 20, window: 20)
        let run = UUID()
        let tooLarge = operation(run: run, count: 21)
        isReview(try await store.reserve(tooLarge, context: .userRequested(), resources: resources(tooLarge)))
        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<40 {
                let op = operation(run: run), current = resources(op)
                group.addTask {
                    if case .allow = try await store.reserve(op, context: .userRequested(), resources: current) { return true }
                    return false
                }
            }
            var allowed = 0
            for try await result in group { if result { allowed += 1 } }
            return allowed
        }
        XCTAssertEqual(results, 20)
        let newRun = operation()
        isReview(try await store.reserve(newRun, context: .userRequested(), resources: resources(newRun)))
    }

    func testRetryDigestAndDispatchAreIdempotent() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir); try await configure(store, limit: 1)
        let op = operation()
        let envelope = try allowed(await store.reserve(op, context: .userRequested(), resources: resources(op)))
        for _ in 0..<5 {
            let retry = try allowed(await store.reserve(op, context: .userRequested(), resources: resources(op)))
            XCTAssertEqual(retry, envelope)
            XCTAssertEqual(retry.operation.digest, op.digest)
        }
        let changed = operation(id: op.operationID, run: op.runID, effect: "Changed title")
        XCTAssertNotEqual(changed.digest, op.digest)
        isDenied(try await store.reserve(changed, context: .userRequested(), resources: resources(changed)))
        try await store.beginDispatch(envelope, resources: resources(op))
        do { try await store.beginDispatch(envelope, resources: resources(op)); XCTFail("Second dispatch") }
        catch { XCTAssertEqual(error as? AgentPermissionError, .alreadyDispatched) }
        try await store.settle(envelope, outcome: .succeeded)
        isDenied(try await store.reserve(op, context: .userRequested(), resources: resources(op)))
    }

    func testUnknownRetainsCapacityAndKnownNoEffectCanRetry() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir); try await configure(store, limit: 1, window: 1)
        let op = operation()
        let envelope = try allowed(await store.reserve(op, context: .userRequested(), resources: resources(op)))
        try await store.beginDispatch(envelope, resources: resources(op))
        try await store.settle(envelope, outcome: .unknown)
        let other = operation()
        isReview(try await store.reserve(other, context: .userRequested(), resources: resources(other)))
        isDenied(try await store.reserve(op, context: .userRequested(), resources: resources(op)))
        try await store.settle(envelope, outcome: .failedWithoutEffect)
        _ = try allowed(await store.reserve(op, context: .userRequested(), resources: resources(op)))
    }

    func testFreshVersionCancellationAndCapabilityRecheckedAtDispatch() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir)
        try await configure(store, grants: [grant(.taskEdit)])
        let op = operation(action: .taskEdit)
        let envelope = try allowed(await store.reserve(op, context: .userRequested(), resources: resources(op)))
        let stale = AgentPermissionResources(ownerID: op.ownerID, deviceID: op.deviceID,
            versions: [:], writableCalendarIDs: [], supportedActions: [.taskEdit], cancelled: false)
        let unsupported = AgentPermissionResources(ownerID: op.ownerID, deviceID: op.deviceID,
            versions: op.expectedVersions, writableCalendarIDs: [], supportedActions: [], cancelled: false)
        for current in [stale, unsupported, resources(op, cancelled: true)] {
            do { try await store.beginDispatch(envelope, resources: current); XCTFail("Invalid dispatch") }
            catch { XCTAssertEqual(error as? AgentPermissionError, .invalidEnvelope) }
        }
        try await store.beginDispatch(envelope, resources: resources(op))
    }

    func testCorruptAndWrongAccountFilesNeverOverwritten() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("agent-permissions.json"), corrupt = Data("broken JSON".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try store(dir))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        try FileManager.default.removeItem(at: url)
        let first = try store(dir); try await configure(first); await first.close()
        let data = try Data(contentsOf: url)
        XCTAssertThrowsError(try AgentPermissionStore(directory: dir, ownerID: "other", deviceID: "fictional-device"))
        XCTAssertThrowsError(try AgentPermissionStore(directory: dir, ownerID: "fictional-owner", deviceID: "other"))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testRestartPreservesLedgerAndCannotReplayHistory() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try store(dir); try await configure(first, limit: 1, window: 1)
        let op = operation()
        let envelope = try allowed(await first.reserve(op, context: .userRequested(), resources: resources(op)))
        try await first.beginDispatch(envelope, resources: resources(op))
        await first.close()
        let reopened = try store(dir)
        let record = try await reopened.operationRecord(op.operationID)
        let records = try await reopened.operationRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record?.status, "dispatched")
        XCTAssertEqual(record?.envelope, envelope)
        isDenied(try await reopened.reserve(op, context: .userRequested(), resources: resources(op)))
        do { try await reopened.beginDispatch(envelope, resources: resources(op)); XCTFail("History dispatch") }
        catch { XCTAssertEqual(error as? AgentPermissionError, .invalidEnvelope) }
        let other = operation()
        isReview(try await reopened.reserve(other, context: .userRequested(), resources: resources(other)))
    }

    func testSecondStoreOwnerIsRejected() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try store(dir)
        XCTAssertThrowsError(try store(dir)) { XCTAssertEqual($0 as? AgentPermissionError, .storeAlreadyOpen) }
        await first.close()
        let second = try store(dir); await second.close()
    }

    func testExpiryAndWindowUseInjectedClock() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestPermissionClock(now)
        let store = try AgentPermissionStore(directory: dir, ownerID: "fictional-owner", deviceID: "fictional-device",
                                             reservationTTL: 10, clock: { clock.read() })
        try await configure(store, limit: 1, window: 1)
        let op = operation()
        let envelope = try allowed(await store.reserve(op, context: .userRequested(), resources: resources(op)))
        clock.advance(11)
        do { try await store.beginDispatch(envelope, resources: resources(op)); XCTFail("Expired") }
        catch { XCTAssertEqual(error as? AgentPermissionError, .invalidEnvelope) }
        let other = operation()
        let record = try await store.operationRecord(op.operationID)
        XCTAssertEqual(record?.status, "released")
        _ = try allowed(await store.reserve(other, context: .userRequested(), resources: resources(other)))
    }

    func testExpiryReleasesRunAndWindowCapacityAtExactBoundary() async throws {
        // Exercise each limit independently; released rows must not count in either budget.
        for limits in [(1, 10), (10, 1)] {
            let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let clock = TestPermissionClock(now)
            let store = try AgentPermissionStore(directory: dir, ownerID: "fictional-owner", deviceID: "fictional-device",
                                                 reservationTTL: 10, clock: { clock.read() })
            try await configure(store, limit: limits.0, window: limits.1)
            let op = operation(), other = operation()
            let old = try allowed(await store.reserve(op, context: .userRequested(), resources: resources(op)))
            let next = operation(run: op.runID)
            clock.advance(9)
            isReview(try await store.reserve(next, context: .userRequested(), resources: resources(next)))
            clock.advance(1)
            _ = try allowed(await store.reserve(next, context: .userRequested(), resources: resources(next)))
            let released = try await store.operationRecord(op.operationID)
            XCTAssertEqual(released?.status, "released")
            // Window capacity is still enforced for the replacement in a different run.
            if limits.1 == 1 {
                isReview(try await store.reserve(other, context: .userRequested(), resources: resources(other)))
            }
            clock.advance(-10)
            do { try await store.beginDispatch(old, resources: resources(op)); XCTFail("Clock rollback revived expiry") }
            catch { XCTAssertEqual(error as? AgentPermissionError, .invalidEnvelope) }
            await store.close()
            let reopened = try self.store(dir)
            let durable = try await reopened.operationRecord(op.operationID)
            XCTAssertEqual(durable?.status, "released")
        }
    }

    func testExpiredRetryRequiresFreshPolicyResourcesAndContext() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestPermissionClock(now)
        let store = try AgentPermissionStore(directory: dir, ownerID: "fictional-owner", deviceID: "fictional-device",
                                             reservationTTL: 10, clock: { clock.read() })
        try await configure(store, grants: [], limit: 1, window: 1)
        let op = operation(action: .taskEdit)
        let old = try allowed(await store.reserve(op, context: .directTaskSubmission(op), resources: resources(op)))
        clock.advance(10)
        // The previous exact UI submission is not carried into a generic invocation.
        isReview(try await store.reserve(op, context: .userRequested(), resources: resources(op)))
        isDenied(try await store.reserve(op, context: .directTaskSubmission(op), resources: resources(op, cancelled: true)))
        let stale = AgentPermissionResources(ownerID: op.ownerID, deviceID: op.deviceID, versions: [:],
            writableCalendarIDs: [], supportedActions: [.taskEdit], cancelled: false)
        isDenied(try await store.reserve(op, context: .directTaskSubmission(op), resources: stale))
        let changed = operation(id: op.operationID, run: op.runID, action: .taskEdit, effect: "Different effect")
        isDenied(try await store.reserve(changed, context: .directTaskSubmission(changed), resources: resources(changed)))
        try await configure(store, grants: [grant(.taskEdit)], limit: 1, window: 1, revision: 1)
        let replacement = try allowed(await store.reserve(op, context: .userRequested(), resources: resources(op)))
        XCTAssertNotEqual(old.reservationID, replacement.reservationID)
        XCTAssertEqual(replacement.operation.digest, old.operation.digest)
        XCTAssertEqual(replacement.policyRevision, 2)
        do { try await store.settle(old, outcome: .failedWithoutEffect); XCTFail("Old expiry settled replacement") }
        catch { XCTAssertEqual(error as? AgentPermissionError, .invalidEnvelope) }
        do { try await store.beginDispatch(old, resources: resources(op)); XCTFail("Old expiry dispatched") }
        catch { XCTAssertEqual(error as? AgentPermissionError, .invalidEnvelope) }
        try await store.beginDispatch(replacement, resources: resources(op))
    }

    func testRestartReleasesOnlyReservedCapacityAndRechecksPolicy() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try store(dir); try await configure(first, limit: 1, window: 1)
        let op = operation()
        let old = try allowed(await first.reserve(op, context: .userRequested(), resources: resources(op)))
        try await configure(first, grants: [], limit: 1, window: 1, revision: 1)
        await first.close()
        let second = try store(dir)
        let recovered = try await second.operationRecord(op.operationID)
        XCTAssertEqual(recovered?.status, "released")
        isReview(try await second.reserve(op, context: .userRequested(), resources: resources(op)))
        try await configure(second, limit: 1, window: 1, revision: 2)
        // Same run proves both budgets were freed even before the original TTL expired.
        let next = operation(run: op.runID)
        _ = try allowed(await second.reserve(next, context: .userRequested(), resources: resources(next)))
        do { try await second.beginDispatch(old, resources: resources(op)); XCTFail("Restart revived old envelope") }
        catch { XCTAssertEqual(error as? AgentPermissionError, .invalidEnvelope) }
    }

    func testExpiryAndRestartNeverReleaseDispatchedUnknownOrSucceeded() async throws {
        for outcome in ["dispatched", "unknown", "succeeded"] {
            let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let clock = TestPermissionClock(now)
            let first = try AgentPermissionStore(directory: dir, ownerID: "fictional-owner", deviceID: "fictional-device",
                                                 reservationTTL: 10, clock: { clock.read() })
            try await configure(first, limit: 1, window: 1)
            let op = operation()
            let envelope = try allowed(await first.reserve(op, context: .userRequested(), resources: resources(op)))
            try await first.beginDispatch(envelope, resources: resources(op))
            if outcome == "unknown" { try await first.settle(envelope, outcome: .unknown) }
            if outcome == "succeeded" { try await first.settle(envelope, outcome: .succeeded) }
            clock.advance(10)
            let next = operation(run: op.runID)
            isReview(try await first.reserve(next, context: .userRequested(), resources: resources(next)))
            await first.close()
            let second = try AgentPermissionStore(directory: dir, ownerID: "fictional-owner", deviceID: "fictional-device",
                                                  clock: { clock.read() })
            clock.advance(4000)
            let record = try await second.operationRecord(op.operationID)
            XCTAssertEqual(record?.status, outcome)
            isDenied(try await second.reserve(op, context: .userRequested(), resources: resources(op)))
            // Renew grant after the window, without altering cumulative per-run accounting.
            try await configure(second, grants: [grant(expires: clock.read().addingTimeInterval(3600))],
                                limit: 1, window: 1, revision: 1)
            isReview(try await second.reserve(next, context: .userRequested(), resources: resources(next)))
            let newRun = operation()
            let decision = try await second.reserve(newRun, context: .userRequested(), resources: resources(newRun))
            if outcome == "succeeded" { _ = try allowed(decision) }
            else { isReview(decision) }
        }
    }

    func testFailedExpiryPersistenceCannotPublishReplacementAuthority() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestPermissionClock(now)
        let first = try AgentPermissionStore(directory: dir, ownerID: "fictional-owner", deviceID: "fictional-device",
                                             reservationTTL: 10, clock: { clock.read() })
        try await configure(first, limit: 1, window: 1)
        let op = operation()
        let old = try allowed(await first.reserve(op, context: .userRequested(), resources: resources(op)))
        let url = dir.appendingPathComponent("agent-permissions.json")
        let backup = dir.appendingPathComponent("saved-ledger.json")
        try FileManager.default.moveItem(at: url, to: backup)
        // An occupied directory makes the atomic rename fail, with no new authority returned.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        clock.advance(10)
        do { _ = try await first.reserve(op, context: .userRequested(), resources: resources(op)); XCTFail("Persistence failure allowed retry") }
        catch { XCTAssertEqual(error as? AgentPermissionError, .corruptStore) }
        do { try await first.beginDispatch(old, resources: resources(op)); XCTFail("Failed store dispatched") }
        catch { XCTAssertEqual(error as? AgentPermissionError, .corruptStore) }
        await first.close()
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: backup, to: url)
        let second = try store(dir)
        let replacement = try allowed(await second.reserve(op, context: .userRequested(), resources: resources(op)))
        XCTAssertNotEqual(old.reservationID, replacement.reservationID)
    }

    func testAllTaskFamiliesUseTheirOwnGrantAndFields() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir)
        let cases: [(AgentPermissionAction, Set<String>)] = [(.taskCreate, ["title"]), (.taskLink, ["sourceLink"]),
            (.taskEdit, ["notes"]), (.taskComplete, ["completed"]), (.taskArchive, ["deleted"]), (.taskReorder, ["rank"])]
        try await configure(store, grants: cases.map { grant($0.0, fields: $0.1) })
        for (action, fields) in cases {
            let op = operation(action: action, fields: fields)
            let envelope = try allowed(await store.reserve(op, context: .userRequested(), resources: resources(op)))
            try await store.beginDispatch(envelope, resources: resources(op))
            try await store.settle(envelope, outcome: .succeeded)
            let record = try await store.operationRecord(op.operationID)
            XCTAssertEqual(record?.status, "succeeded")
        }
    }

    func testReleasedAttemptCannotDispatchOrSettleItsReplacement() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir); try await configure(store)
        let op = operation()
        let old = try allowed(await store.reserve(op, context: .userRequested(), resources: resources(op)))
        try await store.settle(old, outcome: .failedWithoutEffect)
        let replacement = try allowed(await store.reserve(op, context: .userRequested(), resources: resources(op)))
        XCTAssertNotEqual(old.reservationID, replacement.reservationID)
        do { try await store.beginDispatch(old, resources: resources(op)); XCTFail("Stale attempt") }
        catch { XCTAssertEqual(error as? AgentPermissionError, .invalidEnvelope) }
        do { try await store.settle(old, outcome: .failedWithoutEffect); XCTFail("Stale release") }
        catch { XCTAssertEqual(error as? AgentPermissionError, .invalidEnvelope) }
        try await store.beginDispatch(replacement, resources: resources(op))
    }

    func testUndispatchedRestartIsEvidenceOnlyAndPolicyPersists() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try store(dir); try await configure(first)
        let policy = try await first.snapshot(), op = operation()
        let envelope = try allowed(await first.reserve(op, context: .userRequested(), resources: resources(op)))
        await first.close()
        let second = try store(dir)
        let restored = try await second.snapshot()
        XCTAssertEqual(restored, policy)
        let recovered = try await second.operationRecord(op.operationID)
        XCTAssertEqual(recovered?.status, "released")
        do { try await second.beginDispatch(envelope, resources: resources(op)); XCTFail("Restored dispatch") }
        catch { XCTAssertEqual(error as? AgentPermissionError, .invalidEnvelope) }
        let replacement = try allowed(await second.reserve(op, context: .userRequested(), resources: resources(op)))
        XCTAssertNotEqual(replacement.reservationID, envelope.reservationID)
        let permissions = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("agent-permissions.json").path)
        XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testSettledWindowRollsForwardButUnknownDoesNotExpire() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestPermissionClock(now)
        let store = try AgentPermissionStore(directory: dir, ownerID: "fictional-owner", deviceID: "fictional-device",
                                             clock: { clock.read() })
        try await configure(store, grants: [grant(expires: now.addingTimeInterval(10000))], limit: 1, window: 1)
        let first = operation()
        let envelope = try allowed(await store.reserve(first, context: .userRequested(), resources: resources(first)))
        try await store.beginDispatch(envelope, resources: resources(first))
        try await store.settle(envelope, outcome: .succeeded)
        clock.advance(3601)
        let next = operation()
        let nextEnvelope = try allowed(await store.reserve(next, context: .userRequested(), resources: resources(next)))
        try await store.beginDispatch(nextEnvelope, resources: resources(next))
        try await store.settle(nextEnvelope, outcome: .unknown)
        clock.advance(3601)
        let third = operation()
        isReview(try await store.reserve(third, context: .userRequested(), resources: resources(third)))
    }

    func testCalendarEditRequiresVersionAndBulkStaysInReview() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir)
        try await configure(store, grants: [grant(.calendarEdit, calendar: ["fictional-calendar"])])
        let op = operation(action: .calendarEdit, calendar: ["fictional-calendar"])
        let envelope = try allowed(await store.reserve(op, context: .userRequested(), resources: resources(op)))
        try await store.beginDispatch(envelope, resources: resources(op))
        let bulk = operation(action: .calendarEdit, count: 2, calendar: ["fictional-calendar"])
        isReview(try await store.reserve(bulk, context: .userRequested(), resources: resources(bulk)))
    }

    func testConcurrentIdenticalRetryUsesOneReservation() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir); try await configure(store, limit: 1, window: 2)
        let op = operation(), current = resources(op)
        let envelopes = try await withThrowingTaskGroup(of: AgentPermissionEnvelope.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    guard case .allow(let envelope) = try await store.reserve(op, context: .userRequested(), resources: current) else {
                        throw AgentPermissionError.invalidEnvelope
                    }
                    return envelope
                }
            }
            var values: [AgentPermissionEnvelope] = []
            for try await envelope in group { values.append(envelope) }
            return values
        }
        XCTAssertEqual(Set(envelopes.map(\.reservationID)).count, 1)
        let extra = operation(run: op.runID)
        isReview(try await store.reserve(extra, context: .userRequested(), resources: resources(extra)))
        let nextRun = operation()
        _ = try allowed(await store.reserve(nextRun, context: .userRequested(), resources: resources(nextRun)))
    }

    func testSerializedDecisionIsEvidenceAndTamperingCannotMintDispatch() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir); try await configure(store)
        let op = operation()
        let decision = try await store.reserve(op, context: .userRequested(), resources: resources(op))
        let data = try JSONEncoder().encode(decision)
        XCTAssertEqual(try JSONDecoder().decode(AgentPermissionDecision.self, from: data), decision)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["userPresent"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(AgentPermissionDecision.self, from: JSONSerialization.data(withJSONObject: object)))
        object.removeValue(forKey: "userPresent")
        var envelopeJSON = try XCTUnwrap(object["envelope"] as? [String: Any])
        envelopeJSON["reservationID"] = UUID().uuidString; object["envelope"] = envelopeJSON
        let tampered = try JSONDecoder().decode(AgentPermissionDecision.self, from: JSONSerialization.data(withJSONObject: object))
        let envelope = try allowed(tampered)
        do { try await store.beginDispatch(envelope, resources: resources(op)); XCTFail("Forged reservation") }
        catch { XCTAssertEqual(error as? AgentPermissionError, .invalidEnvelope) }
    }

    func testUnknownJSONFieldsActionsAndEffectFieldsFailClosed() async throws {
        let op = operation(), data = try JSONEncoder().encode(op)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["userPresent"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(AgentPermissionOperation.self, from: JSONSerialization.data(withJSONObject: json)))
        json.removeValue(forKey: "userPresent"); json["action"] = "inventedAction"
        XCTAssertThrowsError(try JSONDecoder().decode(AgentPermissionOperation.self, from: JSONSerialization.data(withJSONObject: json)))
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir)
        let bad = operation(fields: ["unknownField"])
        isDenied(try await store.reserve(bad, context: .directTaskSubmission(bad), resources: resources(bad)))
        try await configure(store); await store.close()
        let url = dir.appendingPathComponent("agent-permissions.json")
        var disk = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var policy = try XCTUnwrap(disk["policy"] as? [String: Any]); policy["autoApprove"] = true; disk["policy"] = policy
        let corrupt = try JSONSerialization.data(withJSONObject: disk); try corrupt.write(to: url)
        XCTAssertThrowsError(try self.store(dir))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
}

private final class TestPermissionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(interval) }
}
