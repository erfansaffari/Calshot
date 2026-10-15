import AppKit
import SwiftUI

struct CalendarBatchReviewView: View {
    @ObservedObject var model: CalshotModel
    @ObservedObject var coordinator: CalendarActionCoordinator
    @State private var reviewing = false
    @State private var focusedID: UUID?
    @State private var year = ""
    @State private var coursePrefix = ""
    @State private var showSource = false
    @State private var editFocusToken = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            if reviewing {
                controls
                GeometryReader { geometry in
                    if geometry.size.width >= 700 {
                        HStack(alignment: .top, spacing: 16) {
                            itemList.frame(width: max(240, geometry.size.width * 0.37))
                            Divider()
                            editor.frame(maxWidth: .infinity)
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                itemList.frame(height: 180)
                                editor.frame(minHeight: 340)
                            }
                        }
                    }
                }
            } else if let image = model.image {
                ScreenshotCanvasView(image: image, onRetake: { Task { await model.capture() } })
                    .frame(maxHeight: .infinity)
            }
            footer
        }
        .task(id: "\(reviewing)-\(model.selectedCalendarID ?? "")") {
            guard reviewing else { return }
            if model.destinations.isEmpty { await model.loadCalendars() }
            if let id = model.selectedCalendarID { await coordinator.checkDuplicates(destinationID: id) }
        }
        .onChange(of: coordinator.proposals.map(\.id)) { _, ids in
            if focusedID == nil || !ids.contains(focusedID!) { focusedID = ids.first }
        }
        .onAppear {
            focusedID = coordinator.proposals.first?.id
            reviewing = model.agentIsWaitingForApproval
        }
        .onChange(of: model.agentIsWaitingForApproval) { _, waiting in
            if waiting { reviewing = true; focusedID = coordinator.proposals.first(where: { !$0.isFinished })?.id }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(coordinator.proposals.isEmpty ? "No calendar items found" : "Found \(coordinator.proposals.count) calendar items", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
            }
            HStack {
                if !reviewing && !coordinator.proposals.isEmpty {
                    Button("Review calendar items") { reviewing = true }.buttonStyle(.borderedProminent)
                }
                Button("Add screenshot") { Task { await model.capture(appendToBatch: true) } }.disabled(coordinator.isExecuting)
                Button("Add manually") {
                    coordinator.addManual()
                    focusedID = coordinator.proposals.last?.id
                    reviewing = true
                }.disabled(coordinator.isExecuting || model.agentIsRunning)
                Spacer()
            }
            Text("Review calendar actions before approving them. You can edit details or skip individual items.")
                .font(.caption).foregroundStyle(.secondary)
            if let status = model.status { Text(status).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Select ready") { coordinator.selectReady() }
                Button("Skip all") { coordinator.skipAll() }
                Spacer()
                if coordinator.isCheckingDuplicates { ProgressView().controlSize(.small); Text("Checking calendar…").font(.caption) }
                Button("Check duplicates") {
                    if let id = model.selectedCalendarID { Task { await coordinator.checkDuplicates(destinationID: id) } }
                }.disabled(model.selectedCalendarID == nil)
            }
            DisclosureGroup("Group settings") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                    TextField("Course prefix, e.g. BIO 101", text: $coursePrefix).textFieldStyle(.roundedBorder)
                    Button("Apply prefix") { coordinator.applyPrefix(coursePrefix) }
                        .disabled(coursePrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    HStack {
                    TextField("Year", text: $year).textFieldStyle(.roundedBorder).frame(width: 75)
                    Button("Confirm missing years") { if let value = Int(year) { coordinator.applyYear(value) } }
                        .disabled(Int(year).map { !(1900...2200).contains($0) } ?? true)
                    Spacer()
                    }
                }
                Button("Use all-day for date-only deadlines") { coordinator.confirmDateOnlyDeadlines() }
                    .help("Applies only to deadlines whose time is missing. Exam times still need review.")
            }
            .font(.caption)
        }
        .disabled(coordinator.isExecuting)
    }

    private var itemList: some View {
        List(selection: $focusedID) {
            ForEach(coordinator.proposals) { item in
                HStack(spacing: 8) {
                    Toggle("Select \(item.draft.title)", isOn: Binding(
                        get: { item.isSelected }, set: { value in coordinator.update(item.id) { $0.isSelected = value } }))
                        .labelsHidden().toggleStyle(.checkbox)
                        .disabled(coordinator.isExecuting || !canSelect(item))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.draft.title.isEmpty ? "Untitled item" : item.draft.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Text("\(operationLabel(item)) · \(item.kind) · \(item.draft.startDate?.formatted(date: .abbreviated, time: item.draft.isAllDay ? .omitted : .shortened) ?? "Date needed")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(item.status).font(.caption2).foregroundStyle(statusColor(item))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .tag(item.id)
                .contextMenu {
                    Button("Edit") { focusedID = item.id }
                    Button(item.isSelected ? "Skip" : "Select") { coordinator.update(item.id) { $0.isSelected.toggle() } }
                        .disabled(coordinator.isExecuting || !canSelect(item))
                }
                .accessibilityElement(children: .contain)
            }
        }
        .listStyle(.inset)
        .onKeyPress(.space) {
            guard let id = focusedID, let item = coordinator.proposals.first(where: { $0.id == id }), !coordinator.isExecuting, canSelect(item) else { return .ignored }
            coordinator.update(id) { $0.isSelected.toggle() }
            return .handled
        }
        .onKeyPress(.return) { editFocusToken = UUID(); return .handled }
    }

    @ViewBuilder private var editor: some View {
        if let item = coordinator.proposals.first(where: { $0.id == focusedID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CalendarProposalEditor(item: item, coordinator: coordinator, focusToken: editFocusToken).id(item.id)
                    DisclosureGroup("Screenshot and source", isExpanded: $showSource) {
                        if let image = model.sourceImage(for: item) { CalendarEvidenceImage(image: image, region: item.draft.sourceRegion).frame(height: 220) }
                        Text(item.draft.sourceText).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }.padding(.trailing, 6)
            }
        } else { Text("Choose an item to review.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let message = coordinator.message { Text(message).font(.caption).textSelection(.enabled) }
            if let message = model.saveMessage { Text(message).font(.caption).foregroundStyle(.orange) }
            HStack {
                if let locked = coordinator.proposals.first(where: { coordinator.isInApprovalScope($0.id) && !$0.isFinished && $0.targetDestinationID != nil }), model.agentIsWaitingForApproval {
                    Label(locked.targetCalendarName ?? "Calendar", systemImage: "calendar").font(.callout)
                } else if model.destinations.isEmpty {
                    Button("Load calendars") { Task { await model.loadCalendars() } }
                } else {
                    Picker("Calendar", selection: Binding(get: { model.selectedCalendarID ?? "" }, set: { model.selectedCalendarID = $0 })) {
                        ForEach(model.destinations) { Text($0.title).tag($0.id) }
                    }.frame(maxWidth: 240).disabled(coordinator.isExecuting)
                }
                Spacer()
                if coordinator.isExecuting {
                    ProgressView().controlSize(.small)
                    Text("Saving approved actions…").font(.caption)
                    Button(coordinator.stopRequested ? "Stopping…" : "Stop remaining") { coordinator.requestStop() }.disabled(coordinator.stopRequested)
                } else {
                    if model.agentIsWaitingForApproval {
                        Button("Skip pending") { model.skipAgentApproval() }
                    } else {
                        Button("Cancel review") { model.cancelReview() }
                    }
                    if reviewing {
                        Button(coordinator.needsDuplicateCheck(destinationID: model.selectedCalendarID ?? "") ? "Check selected items" : "Approve \(coordinator.selectedCount) actions") { Task { await model.saveEvents() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!coordinator.canApprove || model.selectedCalendarID == nil)
                    }
                }
            }
            if reviewing {
                Text("\(coordinator.approvalSummary) · \(coordinator.unresolvedCount) need review")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func operationLabel(_ item: CalendarActionProposal) -> String {
        switch item.operation { case .create: "Add"; case .update: "Change"; case .delete: "Remove"; case .move: "Move" }
    }

    private func canSelect(_ item: CalendarActionProposal) -> Bool {
        guard coordinator.isInApprovalScope(item.id) else { return false }
        guard !item.isFinished, item.state != .saving else { return false }
        if item.operation == .delete { return !(item.targetEventIdentifier?.isEmpty ?? true) }
        return item.isSelected || item.canAdd
    }

    private func statusColor(_ item: CalendarActionProposal) -> Color {
        if item.isFinished { return .green }
        if item.state == .failed || !item.issues.isEmpty || (!item.duplicateIdentifiers.isEmpty && !item.allowDuplicate) { return .orange }
        return .secondary
    }
}

private struct CalendarProposalEditor: View {
    let item: CalendarActionProposal
    @ObservedObject var coordinator: CalendarActionCoordinator
    let focusToken: UUID
    @State private var urlText = ""
    @FocusState private var titleFocused: Bool

    private var zone: TimeZone { item.draft.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current }
    private var editable: Bool { !coordinator.isExecuting && !item.isFinished && item.state != .saving && item.operation != .delete && item.operation != .move }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(item.kind) details").font(.headline)
                Spacer()
                Text(item.status).font(.caption).foregroundStyle(.secondary)
            }
            if let calendar = item.targetCalendarName { Label("Changes apply to \(calendar)", systemImage: "calendar").font(.caption).foregroundStyle(.secondary) }
            if let receipt = item.receipt { Label("\(item.status) · \(receipt.calendarName)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
            if item.operation == .move {
                Label("\(item.sourceCalendarName ?? "Source") → \(item.targetCalendarName ?? "Destination")", systemImage: "arrow.right.circle").font(.headline)
                CalendarEventComparison(draft: item.before ?? item.draft, heading: "Event to move")
                Text(item.moveCopyReceipt == nil ? "Approval adds a copy to the destination, verifies it, then removes the original. If copying fails, the original stays." : "Approval reuses the existing destination copy, restores details from the original if needed, verifies it, then removes the original. No extra copy is added.")
                    .font(.callout).foregroundStyle(.secondary)
                if let copy = item.moveDestinationBefore {
                    CalendarEventComparison(draft: copy, heading: "Existing destination copy")
                    if copy.notes != item.draft.notes { Text("Notes will match the original: \(item.draft.notes ?? "None")").font(.caption) }
                    if copy.location != item.draft.location { Text("Location will match the original: \(item.draft.location ?? "None")").font(.caption) }
                    if copy.url != item.draft.url { Text("Link will match the original: \(item.draft.url?.absoluteString ?? "None")").font(.caption) }
                }
            }
            if item.operation == .update, let before = item.before {
                CalendarEventComparison(draft: before, heading: "Current event")
                Label("Proposed changes", systemImage: "arrow.down").font(.headline)
            }
            if item.operation == .delete {
                CalendarEventComparison(draft: item.before ?? item.draft, heading: "Event to remove")
                if !item.draft.sourceText.isEmpty {
                    Label(item.draft.sourceText, systemImage: "text.bubble").font(.callout).textSelection(.enabled)
                }
                Text("Select this event to approve its removal. Removing it applies to this occurrence.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = item.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if !item.issues.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(item.issues, id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                }
            }
            if item.operation != .delete && item.operation != .move { fields.disabled(!editable) }
            if item.operation == .create && !item.duplicateIdentifiers.isEmpty && !item.isFinished {
                Toggle("Add another copy anyway", isOn: Binding(get: { item.allowDuplicate }, set: { value in
                    coordinator.update(item.id) { $0.allowDuplicate = value }
                })).font(.caption).disabled(!editable)
                Text("A matching title and date already exists in this calendar or batch. Check the source before adding another copy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if editable {
                Button("Confirm reviewed details") {
                    coordinator.edit(item.id) { draft in
                        guard draft.startDate != nil, draft.endDate != nil,
                              !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        draft.ambiguities.removeAll()
                    }
                }
                .disabled(item.draft.startDate == nil || item.draft.endDate == nil || item.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || invalidURL)
                Text("Confirmation accepts the displayed date, year, time, timezone, and duration. Select this item when it is ready.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { urlText = item.draft.url?.absoluteString ?? "" }
        .onChange(of: focusToken) { _, _ in titleFocused = true }
        .onKeyPress(.escape) { titleFocused = false; return .handled }
    }

    private var invalidURL: Bool { !urlText.isEmpty && (URL(string: urlText)?.scheme.map { !["http", "https"].contains($0.lowercased()) } ?? true) }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Event title", text: text(\.title)).textFieldStyle(.roundedBorder).focused($titleFocused)
            Toggle("All-day", isOn: Binding(get: { item.draft.isAllDay }, set: { enabled in
                coordinator.edit(item.id) { CalendarDraftValidation.setAllDay(&$0, enabled: enabled) }
            }))
            DatePicker("Starts", selection: Binding(get: { item.draft.startDate ?? .now }, set: { value in
                coordinator.edit(item.id) { draft in
                    let oldStart = draft.startDate
                    let duration = oldStart.flatMap { start in draft.endDate.map { $0.timeIntervalSince(start) } } ?? 3600
                    draft.startDate = value
                    if draft.isAllDay { CalendarDraftValidation.setAllDay(&draft, enabled: true) }
                    else { draft.endDate = value.addingTimeInterval(duration) }
                    draft.ambiguities.removeAll { [.missingDate, .missingYear, .ambiguousDate, .missingTime, .ambiguousTime].contains($0) }
                }
            }), displayedComponents: item.draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                .environment(\.timeZone, zone)
            if item.draft.startDate == nil {
                Button("Use displayed date") {
                    coordinator.edit(item.id) { draft in
                        draft.startDate = .now
                        draft.endDate = Date.now.addingTimeInterval(3600)
                        if draft.isAllDay { CalendarDraftValidation.setAllDay(&draft, enabled: true) }
                        draft.ambiguities.removeAll { [.missingDate, .missingYear, .ambiguousDate].contains($0) }
                    }
                }.font(.caption)
            }
            if !item.draft.isAllDay {
                DatePicker("Ends", selection: Binding(get: { item.draft.endDate ?? (item.draft.startDate ?? .now).addingTimeInterval(3600) }, set: { value in
                    coordinator.edit(item.id) { draft in draft.endDate = value; draft.ambiguities.removeAll { $0 == .missingEndTime } }
                }), displayedComponents: [.date, .hourAndMinute]).environment(\.timeZone, zone)
            }
            TextField("Timezone (IANA name)", text: optionalText(\.timeZoneIdentifier)).textFieldStyle(.roundedBorder)
            TextField("Location", text: optionalText(\.location)).textFieldStyle(.roundedBorder)
            TextField("Link", text: $urlText).textFieldStyle(.roundedBorder)
                .onChange(of: urlText) { _, value in
                    guard editable, value != (item.draft.url?.absoluteString ?? "") else { return }
                    coordinator.edit(item.id) { draft in
                        draft.url = value.isEmpty ? nil : URL(string: value)
                        draft.ambiguities.removeAll { $0 == .invalidURL }
                        if invalidURL { draft.ambiguities.append(.invalidURL) }
                    }
                }
            if invalidURL { Text("Enter an http or https link.").font(.caption).foregroundStyle(.orange) }
            Text("Notes").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: optionalText(\.notes)).frame(minHeight: 65, maxHeight: 100).border(.secondary.opacity(0.2))
        }
    }

    private func text(_ key: WritableKeyPath<EventDraft, String>) -> Binding<String> {
        Binding(get: { item.draft[keyPath: key] }, set: { value in coordinator.edit(item.id) {
            $0[keyPath: key] = value
            if key == \.title && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { $0.ambiguities.removeAll { $0 == .missingTitle } }
        } })
    }
    private func optionalText(_ key: WritableKeyPath<EventDraft, String?>) -> Binding<String> {
        Binding(get: { item.draft[keyPath: key] ?? "" }, set: { value in coordinator.edit(item.id) { $0[keyPath: key] = value.isEmpty ? nil : value } })
    }
}

private struct CalendarEventComparison: View {
    let draft: EventDraft
    let heading: String

    private var zone: TimeZone { draft.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current }
    private func dateText(_ date: Date?) -> String {
        guard let date else { return "Date not set" }
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = draft.isAllDay ? .none : .short
        return formatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.caption).foregroundStyle(.secondary)
            Text(draft.title).font(.headline)
            Text("\(dateText(draft.startDate)) – \(dateText(draft.endDate))").font(.callout)
            if draft.isAllDay { Text("All-day").font(.caption) }
            if let timeZone = draft.timeZoneIdentifier { Text(timeZone).font(.caption).foregroundStyle(.secondary) }
            if let location = draft.location, !location.isEmpty { Label(location, systemImage: "mappin").font(.caption) }
            if let url = draft.url { Text(url.absoluteString).font(.caption) }
            if let notes = draft.notes, !notes.isEmpty { Text(notes).font(.caption) }
        }
        .textSelection(.enabled)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CalendarEvidenceImage: View {
    let image: NSImage
    let region: SourceRegion?
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / max(1, image.size.width), geometry.size.height / max(1, image.size.height))
            let width = image.size.width * scale
            let height = image.size.height * scale
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().frame(width: width, height: height)
                if let region {
                    Rectangle().fill(.orange.opacity(0.15)).overlay(Rectangle().stroke(.orange, lineWidth: 2))
                        .frame(width: width * region.width, height: height * region.height)
                        .offset(x: width * region.x, y: height * region.y)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel("Captured screenshot with supporting text highlighted")
    }
}
