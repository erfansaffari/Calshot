import AppKit
import Combine
import Sparkle

/// Owns all updater preferences, verification and restart decisions on the Mac.
@MainActor
final class SoftwareUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var status = "Updates haven’t been checked yet."
    @Published private(set) var error: String?
    @Published private(set) var installing = false
    private(set) var hasPendingInstallation = false
    private var controller: SPUStandardUpdaterController?
    private var timer: Timer?
    private var resumeInstallation: (() -> Void)?
    var canRestart: () -> Bool = { false }
    let enabled: Bool
    init(enabled: Bool) { self.enabled = enabled; super.init() }
    var updater: SPUUpdater? { controller?.updater }
    var snapshot: JSONValue {
        .object([
            "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"),
            "build": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"),
            "available": .bool(updater != nil), "canCheck": .bool(updater?.canCheckForUpdates == true && !installing),
            "checking": .bool(updater?.sessionInProgress == true), "status": .string(status),
            "error": error.map(JSONValue.string) ?? .null,
            "automaticChecks": .bool(updater?.automaticallyChecksForUpdates == true),
            "automaticDownloads": .bool(updater?.automaticallyDownloadsUpdates == true),
            "lastChecked": updater?.lastUpdateCheckDate.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "development": .bool(Self.developmentBuild)
        ])
    }
    static var developmentBuild: Bool {
#if DEBUG
        true
#else
        false
#endif
    }
    func start() {
        guard enabled, controller == nil else { return }
        let value = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller = value
        // Development builds permit manual feed checks without replacing local development builds in the background.
        if Self.developmentBuild { value.updater.automaticallyChecksForUpdates = false; value.updater.automaticallyDownloadsUpdates = false }
        do { try value.updater.start() }
        catch { self.error = "Updates couldn’t start. Reopen Calshot and try again."; status = "Update service unavailable." }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.objectWillChange.send()
                self.resumeIfSafe()
            }
        }
    }
    func check() throws {
        guard let controller, controller.updater.canCheckForUpdates, !installing else {
            throw CalendarToolArgumentError("Wait for the current update check to finish.")
        }
        error = nil; status = "Checking for updates…"
        controller.checkForUpdates(nil)
    }
    func setPreferences(checks: Bool, downloads: Bool) throws {
        guard let updater, !updater.sessionInProgress, !installing, !Self.developmentBuild else {
            throw CalendarToolArgumentError("Update preferences are unavailable while checking or in a development build.")
        }
        updater.automaticallyDownloadsUpdates = checks && downloads
        updater.automaticallyChecksForUpdates = checks
        objectWillChange.send()
    }
    /// Returns false when Sparkle may proceed immediately; otherwise retains its restart continuation.
    func postponeRestart(until installHandler: @escaping () -> Void) -> Bool {
        guard !canRestart() else { installing = true; return false }
        resumeInstallation = installHandler
        status = "Update ready. Finish or clear your current task to restart safely."
        return true
    }
    func resumeIfSafe() {
        guard let resume = resumeInstallation, canRestart() else { return }
        resumeInstallation = nil; installing = true
        status = "Restarting to install the update…"
        resume()
    }
    func explainDeferredQuit() {
        status = "Finish or clear your current task before quitting to install the update."
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        error = nil; status = "Calshot \(item.displayVersionString) is available."
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error = error as NSError? {
            installing = false; resumeInstallation = nil; hasPendingInstallation = false
            if error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue { status = "You’re up to date."; self.error = nil }
            else if error.domain == SUSparkleErrorDomain && error.code == SUError.installationCanceledError.rawValue { status = "Update cancelled. You can check again anytime."; self.error = nil }
            else { status = "Update couldn’t finish."; self.error = "Calshot is unchanged. Check your connection and try Check for updates again." }
        }
        if !installing { objectWillChange.send() }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeRestart(until: installHandler)
    }
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        let safe = canRestart()
        installing = safe
        if !safe { status = "Finish or cancel your current task before restarting for the update." }
        return safe
    }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        hasPendingInstallation = true
        status = "Update downloaded. It will install when you quit Calshot."
        return false
    }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { installing = true }
}

extension CalshotModel {
    /// Includes incomplete reviews so downloading an update cannot approve, discard or interrupt calendar work.
    var canRestartForSoftwareUpdate: Bool {
        !agentIsRunning && !isSaving && !isCapturing && !isRecognizing && selectionOverlay == nil &&
        !calendarActions.isCheckingDuplicates && !agentIsWaitingForApproval && agentQuestion == nil &&
        !calendarActions.proposals.contains(where: { !$0.isFinished }) &&
        agentCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !calendarAccountIsConnecting && !chatGPTIsConnecting && !account.busy &&
        !accountSyncBusy && !sharingBusy && !macCalendarSyncBusy
    }
}
