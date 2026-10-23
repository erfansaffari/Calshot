import Foundation
import CryptoKit
import Darwin

// Device-local only. Never include this file's policy/ledger in account sync.
// Native adapters construct operations from validated commands, not model-authored envelopes.
// Each operation describes one family; task authority never authorizes calendar publication.
enum AgentPermissionAction: String, Codable, CaseIterable, Sendable {
    case taskCreate, taskLink, taskEdit, taskComplete, taskArchive, taskReorder
    case calendarCreate, calendarEdit, calendarDelete, calendarMove
    var isTask: Bool { rawValue.hasPrefix("task") }
}

struct AgentPermissionOperation: Codable, Equatable, Sendable {
    let operationID: UUID
    let runID: UUID
    let ownerID: String
    let deviceID: String
    let action: AgentPermissionAction
    let resourceIDs: Set<String>
    let expectedVersions: [String: String]
    let calendarIDs: Set<String>
    let fields: Set<String>
    // SHA256 of the complete normalized effect, including new values. Native computes this.
    let effectDigest: String
    let hasGuestEffects: Bool
    let affectsSeries: Bool
    let hasSharingEffects: Bool

    var digest: String {
        // Sets require explicit sorting for a deterministic digest across launches.
        let parts: [String] = [operationID.uuidString, runID.uuidString, ownerID, deviceID,
            action.rawValue, effectDigest, String(hasGuestEffects), String(affectsSeries), String(hasSharingEffects)]
        let value = DigestContent(parts: parts, resources: resourceIDs.sorted(), versions: expectedVersions,
                                  calendars: calendarIDs.sorted(), fields: fields.sorted())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Self.hash(try! encoder.encode(value))
    }
    static func hash(_ normalizedEffect: Data) -> String {
        SHA256.hash(data: normalizedEffect).map { String(format: "%02x", $0) }.joined()
    }
    private struct DigestContent: Encodable {
        let parts: [String]; let resources: [String]; let versions: [String: String]
        let calendars: [String]; let fields: [String]
    }
}

struct AgentPermissionGrant: Codable, Equatable, Sendable {
    let action: AgentPermissionAction
    let requestedEnabled: Bool
    let backgroundEnabled: Bool
    let calendarIDs: Set<String>
    let fields: Set<String>
    let expiresAt: Date
}

struct AgentPermissionPolicy: Codable, Equatable, Sendable {
    let ownerID: String
    let deviceID: String
    let revision: UInt64
    let grants: [AgentPermissionGrant]
    let maxPerRun: Int
    let maxPerWindow: Int
    let windowSeconds: TimeInterval
}

// No Codable conformance: neither a tool argument nor a restored history can mint presence.
struct AgentPermissionNativeContext: Sendable {
    fileprivate let origin: AgentPermissionOrigin
    fileprivate let exactTaskEffect: AgentPermissionOperation?
    fileprivate var reviewedBeyondQuota = false
    static func userRequested() -> Self { Self(origin: .requested, exactTaskEffect: nil) }
    static func background() -> Self { Self(origin: .background, exactTaskEffect: nil) }
    // Only call for an exact task effect submitted by a native-validated visible UI control.
    // Generic foreground commands use userRequested(); calendar extras need their own permission.
    static func directTaskSubmission(_ shownEffect: AgentPermissionOperation) -> Self {
        Self(origin: .requested, exactTaskEffect: shownEffect)
    }
    // The user explicitly reviewed this exact task-only effect or submitted its visible exact action. That confirmation is
    // operation-scoped authority: it may exceed the saved-grant per-run/per-window quotas (which exist to bound
    // unattended execution), but the reservation still counts toward later quotas and never reaches calendar scope,
    // guests, series or sharing. Never construct this from tool JSON, history or a saved grant.
    static func reviewedTaskSubmission(_ shownEffect: AgentPermissionOperation) -> Self {
        var context = Self(origin: .requested, exactTaskEffect: shownEffect)
        context.reviewedBeyondQuota = true
        return context
    }
}

// Native Settings control callback only; never expose its construction through an agent tool.
// This is a trust-boundary marker, not authentication against arbitrary native code in the app.
struct AgentPermissionSettingsControl: Sendable {
    let ownerID: String
    let deviceID: String
    init(nativeOwnerID: String, nativeDeviceID: String) {
        ownerID = nativeOwnerID; deviceID = nativeDeviceID
    }
}

// Re-read immediately before dispatch. Resources/capabilities must come from native stores/adapters.
struct AgentPermissionResources: Sendable {
    let ownerID: String
    let deviceID: String
    let versions: [String: String]
    let writableCalendarIDs: Set<String>
    let supportedActions: Set<AgentPermissionAction>
    let cancelled: Bool
}

enum AgentPermissionOrigin: String, Codable, Sendable { case requested, background }
struct AgentPermissionEnvelope: Codable, Equatable, Sendable {
    let reservationID: UUID
    let operation: AgentPermissionOperation
    let policyRevision: UInt64
    let origin: AgentPermissionOrigin
    let expiresAt: Date
}
enum AgentPermissionDecision: Codable, Equatable, Sendable {
    case allow(AgentPermissionEnvelope)
    case requireReview(String)
    case deny(String)
}
struct AgentPermissionRecord: Codable, Equatable, Sendable {
    let envelope: AgentPermissionEnvelope
    let reservedAt: Date
    // reserved / dispatched / succeeded / unknown / released; evidence, never execution authority.
    let status: String
}
enum AgentPermissionSettlement: Sendable { case succeeded, unknown, failedWithoutEffect }
enum AgentPermissionError: Error, Equatable {
    case storeAlreadyOpen, closed, invalidPolicy, stalePolicy, invalidEnvelope, alreadyDispatched
    case corruptStore, wrongOwnerOrDevice
}

// One actor owns each account directory. flock rejects a second owner, including another process.
// The ledger fences retries; provider reconciliation is still required for unknown outcomes.
actor AgentPermissionStore {
    fileprivate enum Status: String, Codable, Sendable { case reserved, dispatched, succeeded, unknown, released }
    fileprivate struct Entry: Codable, Sendable {
        let envelope: AgentPermissionEnvelope
        let createdAt: Date
        var status: Status
    }
    fileprivate struct DiskState: Codable, Sendable {
        let schemaVersion: Int
        var policy: AgentPermissionPolicy
        var ledger: [String: Entry]
    }
    private let ownerID: String
    private let deviceID: String
    private let fileURL: URL
    private let clock: @Sendable () -> Date
    private let reservationTTL: TimeInterval
    private var lockFD: Int32
    private var state: DiskState
    private var liveReservations: Set<UUID> = []
    private var persistenceFailed = false

    init(directory: URL, ownerID: String, deviceID: String,
         reservationTTL: TimeInterval = 300, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        guard !ownerID.isEmpty, !deviceID.isEmpty, reservationTTL > 0, reservationTTL.isFinite else {
            throw AgentPermissionError.invalidPolicy
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.appendingPathComponent("agent-permissions.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw AgentPermissionError.corruptStore }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw AgentPermissionError.storeAlreadyOpen
        }
        let url = directory.appendingPathComponent("agent-permissions.json")
        do {
            var initial: DiskState
            if FileManager.default.fileExists(atPath: url.path) {
                initial = try JSONDecoder().decode(DiskState.self, from: Data(contentsOf: url))
                guard initial.schemaVersion == 1 else { throw AgentPermissionError.corruptStore }
            } else {
                initial = DiskState(schemaVersion: 1, policy: AgentPermissionPolicy(ownerID: ownerID,
                    deviceID: deviceID, revision: 0, grants: [], maxPerRun: 20,
                    maxPerWindow: 100, windowSeconds: 3600), ledger: [:])
            }
            guard initial.policy.ownerID == ownerID, initial.policy.deviceID == deviceID else {
                throw AgentPermissionError.wrongOwnerOrDevice
            }
            try Self.validate(initial.policy)
            for (key, entry) in initial.ledger {
                guard key == entry.envelope.operation.operationID.uuidString,
                      entry.envelope.operation.ownerID == ownerID, entry.envelope.operation.deviceID == deviceID,
                      Self.valid(entry.envelope.operation), entry.envelope.policyRevision <= initial.policy.revision else {
                    throw AgentPermissionError.corruptStore
                }
            }
            // beginDispatch durably fences effects before returning. A reserved entry from
            // a previous owner therefore proves no dispatch; never restore its authority.
            var recovered = false
            for key in Array(initial.ledger.keys) where initial.ledger[key]?.status == .reserved {
                initial.ledger[key]?.status = .released
                recovered = true
            }
            if recovered { try Self.write(initial, to: url) }
            self.ownerID = ownerID; self.deviceID = deviceID; fileURL = url
            self.clock = clock; self.reservationTTL = reservationTTL; lockFD = fd; state = initial
        } catch {
            Darwin.close(fd)
            if let error = error as? AgentPermissionError { throw error }
            throw AgentPermissionError.corruptStore
        }
    }
    deinit { if lockFD >= 0 { Darwin.close(lockFD) } }
    func close() { if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 } }
    func snapshot() throws -> AgentPermissionPolicy { try checkOpen(); return state.policy }

    // Recovery can inspect evidence and settle it; returned envelopes cannot bypass beginDispatch.
    func operationRecord(_ operationID: UUID) throws -> AgentPermissionRecord? {
        try checkOpen()
        guard let entry = state.ledger[operationID.uuidString] else { return nil }
        return AgentPermissionRecord(envelope: entry.envelope, reservedAt: entry.createdAt, status: entry.status.rawValue)
    }

    func operationRecords() throws -> [AgentPermissionRecord] {
        try checkOpen()
        return state.ledger.values.map {
            AgentPermissionRecord(envelope: $0.envelope, reservedAt: $0.createdAt, status: $0.status.rawValue)
        }.sorted { $0.reservedAt == $1.reservedAt
            ? $0.envelope.operation.operationID.uuidString < $1.envelope.operation.operationID.uuidString
            : $0.reservedAt < $1.reservedAt }
    }

    // Revision CAS prevents stale Settings snapshots from restoring revoked permissions.
    @discardableResult
    func replaceGrants(_ grants: [AgentPermissionGrant], expectedRevision: UInt64,
                       control: AgentPermissionSettingsControl, maxPerRun: Int = 20,
                       maxPerWindow: Int = 100, windowSeconds: TimeInterval = 3600) throws -> AgentPermissionPolicy {
        try checkOpen()
        guard control.ownerID == ownerID, control.deviceID == deviceID else { throw AgentPermissionError.wrongOwnerOrDevice }
        guard expectedRevision == state.policy.revision, expectedRevision < UInt64.max else { throw AgentPermissionError.stalePolicy }
        let policy = AgentPermissionPolicy(ownerID: ownerID, deviceID: deviceID, revision: expectedRevision + 1,
            grants: grants, maxPerRun: maxPerRun, maxPerWindow: maxPerWindow, windowSeconds: windowSeconds)
        try Self.validate(policy)
        var next = state; next.policy = policy; try persist(next)
        return policy
    }

    // Atomically reserves cumulative capacity before returning authority. Does not execute writes.
    func reserve(_ operation: AgentPermissionOperation, context: AgentPermissionNativeContext,
                 resources: AgentPermissionResources) throws -> AgentPermissionDecision {
        try checkOpen()
        let now = clock()
        try releaseExpiredReservations(at: now)
        if let reason = preflight(operation, resources) { return .deny(reason) }
        let policy = state.policy
        if let existing = state.ledger[operation.operationID.uuidString] {
            guard existing.envelope.operation == operation else { return .deny("Operation ID was reused for a different effect.") }
            guard existing.envelope.origin == context.origin else { return .deny("Invocation origin changed.") }
            if existing.status != .released {
                guard liveReservations.contains(operation.operationID) else { return .deny("Interrupted authorization requires native reconciliation; history cannot authorize dispatch.") }
                guard existing.status == .reserved else { return .deny("Operation already dispatched or settled; reconcile its receipt.") }
                guard existing.envelope.policyRevision == policy.revision, existing.envelope.expiresAt > now else {
                    return .deny("Authorization expired or was revoked.")
                }
                return .allow(existing.envelope)
            }
        }
        if operation.hasSharingEffects { return .deny("Sharing is not supported by this permission kernel.") }
        if operation.hasGuestEffects || operation.affectsSeries || (!operation.action.isTask && operation.resourceIDs.count > 1) || [.calendarDelete, .calendarMove].contains(operation.action) {
            return .requireReview("This effect requires separate review and capability validation.")
        }
        let exactTask = operation.action.isTask && context.origin == .requested && context.exactTaskEffect == operation
        let grant = policy.grants.first { $0.action == operation.action }
        if !exactTask {
            guard let grant, grant.expiresAt > now,
                  context.origin == .requested ? grant.requestedEnabled : grant.backgroundEnabled else {
                return .requireReview("No current permission for this action and invocation.")
            }
            guard operation.fields.isSubset(of: grant.fields), operation.calendarIDs.isSubset(of: grant.calendarIDs) else {
                return .requireReview("The effect exceeds the saved field or calendar scope.")
            }
        }
        let entries = state.ledger.values.filter { $0.status != .released }
        let runCount = entries.filter { $0.envelope.operation.runID == operation.runID }.reduce(0) { $0 + $1.envelope.operation.resourceIDs.count }
        let windowCount = entries.filter {
            $0.createdAt > now.addingTimeInterval(-policy.windowSeconds) || [.reserved, .dispatched, .unknown].contains($0.status)
        }.reduce(0) { $0 + $1.envelope.operation.resourceIDs.count }
        let count = operation.resourceIDs.count
        let reviewedBeyondQuota = exactTask && context.reviewedBeyondQuota
        guard reviewedBeyondQuota || (count <= policy.maxPerRun - runCount && count <= policy.maxPerWindow - windowCount) else {
            return .requireReview("The cumulative action limit has been reached.")
        }
        let expiry = exactTask ? now.addingTimeInterval(reservationTTL) : min(now.addingTimeInterval(reservationTTL), grant!.expiresAt)
        let envelope = AgentPermissionEnvelope(reservationID: UUID(), operation: operation, policyRevision: policy.revision,
                                               origin: context.origin, expiresAt: expiry)
        var next = state
        next.ledger[operation.operationID.uuidString] = Entry(envelope: envelope, createdAt: now, status: .reserved)
        try persist(next)
        liveReservations.insert(operation.operationID)
        return .allow(envelope)
    }

    // Call immediately before the native mutation, with freshly read identity, versions and cancellation.
    // This durable transition permits ONE dispatch. A crash afterwards requires reconciliation, not replay.
    func beginDispatch(_ envelope: AgentPermissionEnvelope, resources: AgentPermissionResources) throws {
        try checkOpen()
        try releaseExpiredReservations(at: clock())
        guard liveReservations.contains(envelope.operation.operationID),
              let entry = state.ledger[envelope.operation.operationID.uuidString], entry.envelope == envelope,
              envelope.policyRevision == state.policy.revision, envelope.expiresAt > clock(),
              preflight(envelope.operation, resources) == nil else { throw AgentPermissionError.invalidEnvelope }
        guard entry.status == .reserved else { throw AgentPermissionError.alreadyDispatched }
        var next = state; next.ledger[envelope.operation.operationID.uuidString]?.status = .dispatched
        try persist(next)
    }

    // failedWithoutEffect is a native proof assertion, never derived from assistant prose/timeouts.
    func settle(_ envelope: AgentPermissionEnvelope, outcome: AgentPermissionSettlement) throws {
        try checkOpen()
        let key = envelope.operation.operationID.uuidString
        guard let entry = state.ledger[key], entry.envelope == envelope else { throw AgentPermissionError.invalidEnvelope }
        let status: Status
        switch outcome {
        case .succeeded:
            guard [.dispatched, .unknown, .succeeded].contains(entry.status) else { throw AgentPermissionError.invalidEnvelope }
            status = .succeeded
        case .unknown:
            guard [.dispatched, .unknown].contains(entry.status) else { throw AgentPermissionError.invalidEnvelope }
            status = .unknown
        case .failedWithoutEffect:
            guard [.reserved, .dispatched, .unknown, .released].contains(entry.status) else { throw AgentPermissionError.invalidEnvelope }
            status = .released
        }
        var next = state; next.ledger[key]?.status = status; try persist(next)
    }

    private func checkOpen() throws {
        if lockFD < 0 { throw AgentPermissionError.closed }
        if persistenceFailed { throw AgentPermissionError.corruptStore }
    }
    // Releasing is durable before capacity can be reused. Removing live authority also
    // prevents clock rollback from reviving an expired envelope. Identical operation IDs
    // may retry via reserve, which rechecks current resources, context, scope and limits.
    private func releaseExpiredReservations(at now: Date) throws {
        var next = state
        let expired = next.ledger.filter { $0.value.status == .reserved && $0.value.envelope.expiresAt <= now }
        guard !expired.isEmpty else { return }
        for key in expired.keys { next.ledger[key]?.status = .released }
        try persist(next)
        for entry in expired.values { liveReservations.remove(entry.envelope.operation.operationID) }
    }

    private func persist(_ next: DiskState) throws {
        do {
            try Self.write(next, to: fileURL)
            state = next // Never publish authority if persistence or its durability check failed.
        } catch {
            // A failed disk acknowledgement can be ambiguous. Reopen/reconcile rather than overwrite it.
            persistenceFailed = true
            throw error
        }
    }

    private static func write(_ next: DiskState, to fileURL: URL) throws {
        let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(".permissions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = try JSONEncoder().encode(next)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw AgentPermissionError.corruptStore
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard Darwin.rename(temporary.path, fileURL.path) == 0 else { throw AgentPermissionError.corruptStore }
        let directoryFD = Darwin.open(fileURL.deletingLastPathComponent().path, O_RDONLY)
        guard directoryFD >= 0 else { throw AgentPermissionError.corruptStore }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw AgentPermissionError.corruptStore }
    }

    private static func validate(_ policy: AgentPermissionPolicy) throws {
        guard (1...1000).contains(policy.maxPerRun), (1...10000).contains(policy.maxPerWindow),
              policy.windowSeconds.isFinite, policy.windowSeconds > 0,
              Set(policy.grants.map(\.action)).count == policy.grants.count,
              policy.grants.allSatisfy({ !$0.fields.isEmpty && $0.fields.isSubset(of: supportedFields($0.action)) &&
                  $0.calendarIDs.allSatisfy { !$0.isEmpty } && $0.expiresAt.timeIntervalSince1970.isFinite &&
                  ($0.action.isTask ? $0.calendarIDs.isEmpty : !$0.calendarIDs.isEmpty) }) else {
            throw AgentPermissionError.invalidPolicy
        }
    }
    private static func supportedFields(_ action: AgentPermissionAction) -> Set<String> {
        switch action {
        case .taskCreate, .taskEdit: return ["title", "notes", "dueDate", "dueTime", "timeZone", "reminderMinutes", "reminderTime", "calendarIntent"]
        case .taskLink: return ["sourceLink", "title", "dueDate", "dueTime", "timeZone", "notes"]
        case .taskComplete: return ["completed"]
        case .taskArchive: return ["deleted"]
        case .taskReorder: return ["rank"]
        case .calendarCreate, .calendarEdit: return ["title", "startDate", "endDate", "isAllDay", "timeZoneIdentifier", "location", "url", "notes"]
        case .calendarDelete: return ["delete"]
        case .calendarMove: return ["destination"]
        }
    }
    private static func valid(_ operation: AgentPermissionOperation) -> Bool {
        !operation.resourceIDs.isEmpty && operation.resourceIDs.count <= 1000 &&
        operation.resourceIDs.allSatisfy { !$0.isEmpty } && !operation.fields.isEmpty &&
        operation.fields.isSubset(of: supportedFields(operation.action)) && operation.calendarIDs.allSatisfy { !$0.isEmpty } &&
        operation.effectDigest.count == 64 && operation.effectDigest.allSatisfy { "0123456789abcdef".contains($0) } &&
        Set(operation.expectedVersions.keys).isSubset(of: operation.resourceIDs) &&
        operation.expectedVersions.values.allSatisfy { !$0.isEmpty } &&
        (operation.action.isTask ? operation.calendarIDs.isEmpty : !operation.calendarIDs.isEmpty) &&
        (operation.action == .taskCreate || operation.action == .calendarCreate ||
         Set(operation.expectedVersions.keys) == operation.resourceIDs)
    }
    private func preflight(_ operation: AgentPermissionOperation, _ resources: AgentPermissionResources) -> String? {
        guard operation.ownerID == ownerID, resources.ownerID == ownerID,
              operation.deviceID == deviceID, resources.deviceID == deviceID else { return "Account or execution device changed." }
        guard Self.valid(operation) else { return "Invalid or unresolved operation envelope." }
        guard !resources.cancelled else { return "The run was cancelled." }
        guard resources.supportedActions.contains(operation.action) else { return "The native executor does not support this action." }
        guard operation.calendarIDs.isSubset(of: resources.writableCalendarIDs) else { return "Calendar write access changed." }
        if operation.action == .taskCreate || operation.action == .calendarCreate {
            guard operation.resourceIDs.allSatisfy({ resources.versions[$0] == nil }) else { return "A new resource ID already exists." }
        }
        guard operation.expectedVersions.allSatisfy({ resources.versions[$0.key] == $0.value }) else { return "A resource version changed." }
        return nil
    }
}

// Swift's default keyed decoding ignores unknown fields. Authorization data must fail closed.
private struct AgentPermissionJSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func permissionKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: AgentPermissionJSONKey.self)
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown authorization field"))
    }
}

extension AgentPermissionOperation {
    init(from decoder: Decoder) throws {
        try permissionKeys(decoder, allowed: ["operationID", "runID", "ownerID", "deviceID", "action", "resourceIDs", "expectedVersions", "calendarIDs", "fields", "effectDigest", "hasGuestEffects", "affectsSeries", "hasSharingEffects"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try c.decode(UUID.self, forKey: .operationID)
        runID = try c.decode(UUID.self, forKey: .runID)
        ownerID = try c.decode(String.self, forKey: .ownerID)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        action = try c.decode(AgentPermissionAction.self, forKey: .action)
        resourceIDs = try c.decode(Set<String>.self, forKey: .resourceIDs)
        expectedVersions = try c.decode([String: String].self, forKey: .expectedVersions)
        calendarIDs = try c.decode(Set<String>.self, forKey: .calendarIDs)
        fields = try c.decode(Set<String>.self, forKey: .fields)
        effectDigest = try c.decode(String.self, forKey: .effectDigest)
        hasGuestEffects = try c.decode(Bool.self, forKey: .hasGuestEffects)
        affectsSeries = try c.decode(Bool.self, forKey: .affectsSeries)
        hasSharingEffects = try c.decode(Bool.self, forKey: .hasSharingEffects)
    }
}

extension AgentPermissionGrant {
    init(from decoder: Decoder) throws {
        try permissionKeys(decoder, allowed: ["action", "requestedEnabled", "backgroundEnabled", "calendarIDs", "fields", "expiresAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(AgentPermissionAction.self, forKey: .action)
        requestedEnabled = try c.decode(Bool.self, forKey: .requestedEnabled)
        backgroundEnabled = try c.decode(Bool.self, forKey: .backgroundEnabled)
        calendarIDs = try c.decode(Set<String>.self, forKey: .calendarIDs)
        fields = try c.decode(Set<String>.self, forKey: .fields)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
    }
}

extension AgentPermissionPolicy {
    init(from decoder: Decoder) throws {
        try permissionKeys(decoder, allowed: ["ownerID", "deviceID", "revision", "grants", "maxPerRun", "maxPerWindow", "windowSeconds"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ownerID = try c.decode(String.self, forKey: .ownerID)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        revision = try c.decode(UInt64.self, forKey: .revision)
        grants = try c.decode([AgentPermissionGrant].self, forKey: .grants)
        maxPerRun = try c.decode(Int.self, forKey: .maxPerRun)
        maxPerWindow = try c.decode(Int.self, forKey: .maxPerWindow)
        windowSeconds = try c.decode(TimeInterval.self, forKey: .windowSeconds)
    }
}

extension AgentPermissionEnvelope {
    init(from decoder: Decoder) throws {
        try permissionKeys(decoder, allowed: ["reservationID", "operation", "policyRevision", "origin", "expiresAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reservationID = try c.decode(UUID.self, forKey: .reservationID)
        operation = try c.decode(AgentPermissionOperation.self, forKey: .operation)
        policyRevision = try c.decode(UInt64.self, forKey: .policyRevision)
        origin = try c.decode(AgentPermissionOrigin.self, forKey: .origin)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
    }
}

extension AgentPermissionStore.Entry {
    init(from decoder: Decoder) throws {
        try permissionKeys(decoder, allowed: ["envelope", "createdAt", "status"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        envelope = try c.decode(AgentPermissionEnvelope.self, forKey: .envelope)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        status = try c.decode(AgentPermissionStore.Status.self, forKey: .status)
    }
}

extension AgentPermissionStore.DiskState {
    init(from decoder: Decoder) throws {
        try permissionKeys(decoder, allowed: ["schemaVersion", "policy", "ledger"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        policy = try c.decode(AgentPermissionPolicy.self, forKey: .policy)
        ledger = try c.decode([String: AgentPermissionStore.Entry].self, forKey: .ledger)
    }
}

// Decisions can be shown/persisted as evidence, but dispatch still requires the store's live reservation.
extension AgentPermissionDecision {
    private enum CodingKeys: String, CodingKey { case kind, envelope, reason }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "allow":
            try permissionKeys(decoder, allowed: ["kind", "envelope"])
            self = .allow(try c.decode(AgentPermissionEnvelope.self, forKey: .envelope))
        case "requireReview", "deny":
            try permissionKeys(decoder, allowed: ["kind", "reason"])
            let reason = try c.decode(String.self, forKey: .reason)
            self = kind == "deny" ? .deny(reason) : .requireReview(reason)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown permission decision")
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allow(let envelope):
            try c.encode("allow", forKey: .kind); try c.encode(envelope, forKey: .envelope)
        case .requireReview(let reason):
            try c.encode("requireReview", forKey: .kind); try c.encode(reason, forKey: .reason)
        case .deny(let reason):
            try c.encode("deny", forKey: .kind); try c.encode(reason, forKey: .reason)
        }
    }
}
