import AppKit
import AuthenticationServices
import Combine
import Foundation
import Auth

/// Calshot identity is separate from calendar OAuth and AI billing credentials.
/// Supabase Auth owns PKCE, verification and refresh; sessions stay in Keychain.
@MainActor
final class CalshotAccountService: ObservableObject {
    static let projectURL = URL(string: "https://gjdzybwjmwixsypsyzem.supabase.co")!
    static let publishableKey = "sb_publishable_Lp5OZ2iVor3xDtBHcnCykQ_X2ts7ThA"
    static let redirectURL = URL(string: "calshot://auth/callback")!
    let enabled: Bool
    @Published private(set) var userID: UUID?
    @Published private(set) var email = ""
    @Published private(set) var phase = "restoring"
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    @Published private(set) var googleEnabled = false
    @Published private(set) var onboarded = false
    @Published private(set) var signInProvider = "email"
    @Published private(set) var identityProviders: [String] = []
    @Published private(set) var aiSetupConfirmed = false
    private let preferences: UserDefaults
    var onAuthenticated: ((String) -> Void)?
    var onShowWindow: (() -> Void)?
    private let webAuthentication = AccountWebAuthentication()
    private let client: AuthClient?
    private var observer: Task<Void, Never>?
    private var generation = UUID()
    var requiresLogin: Bool { enabled && userID == nil }
    var canUseWorkspace: Bool { !enabled || (userID != nil && onboarded && phase != "passwordRecovery") }
    var busy: Bool { phase == "restoring" || phase == "working" }

    init(enabled: Bool = true, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.enabled = enabled
        guard enabled else { client = nil; phase = "signedOut"; return }
        client = AuthClient(configuration: .init(url: Self.projectURL.appendingPathComponent("auth/v1"),
            headers: ["apikey": Self.publishableKey], flowType: .pkce, redirectToURL: Self.redirectURL,
            storageKey: "calshot.supabase.session", localStorage: KeychainLocalStorage(service: "com.calshot.accounts")))
        observer = Task { [weak self, client] in
            guard let client else { return }
            for await (event, session) in client.authStateChanges {
                guard !Task.isCancelled, let self else { return }
                if event == .signedOut { self.userID = nil; self.onboarded = false; self.phase = "signedOut" }
                if event == .passwordRecovery, session != nil { self.phase = "passwordRecovery" }
            }
        }
        Task { [weak self] in await self?.restore(); await self?.refreshProviders() }
    }
    deinit { observer?.cancel() }
    func refreshProviders() async {
        guard enabled else { return }
        var request = URLRequest(url: Self.projectURL.appendingPathComponent("auth/v1/settings"))
        request.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        if let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let external = value["external"] as? [String: Any] {
            googleEnabled = external["google"] as? Bool == true
        }
    }
    func restore() async {
        guard let client else { return }
        phase = "restoring"; error = nil
        let id = generation
        do {
            guard client.currentSession != nil else { phase = "signedOut"; return }
            _ = try await client.session
            let user = try await client.user()
            guard generation == id else { return }
            accept(user, provider: "restored")
        } catch { guard generation == id else { return }; phase = "signedOut"; self.error = "Couldn’t restore your account. Check your connection and sign in again, or retry." }
    }
    /// Called only with the SDK's verified user. Provider/email never choose the
    /// account ID: Supabase owns verified identity linking and canonical user IDs.
    func accept(_ user: User, provider: String) {
        userID = user.id; email = user.email ?? ""; error = nil; message = nil; phase = "signedIn"
        let key = "calshot.identity-provider." + user.id.uuidString
        identityProviders = (user.identities ?? []).map(\.provider)
        signInProvider = Self.resolvedProvider(route: provider, identities: identityProviders, saved: preferences.string(forKey: key))
        preferences.set(signInProvider, forKey: key)
        onboarded = preferences.bool(forKey: "calshot.onboarded.\(user.id.uuidString)")
        aiSetupConfirmed = onboarded || preferences.bool(forKey: "calshot.ai-setup.\(user.id.uuidString)")
        onAuthenticated?(provider)
    }
    static func resolvedProvider(route: String, identities: [String], saved: String?) -> String {
        if route == "email" { return "email" }
        if route == "google", identities.contains("google") { return "google" }
        if route == "restored", let saved,
           ["google", "email"].contains(saved), identities.contains(saved) { return saved }
        if identities.contains("google") { return "google" }
        return "email"
    }
    func confirmAISetup() {
        guard let userID else { return }
        preferences.set(true, forKey: "calshot.ai-setup.\(userID.uuidString)"); aiSetupConfirmed = true
    }
    func signIn(email: String, password: String, signUp: Bool, name: String = "") async throws {
        guard let client, !busy else { throw CalendarToolArgumentError("Wait for sign-in to finish.") }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.count <= 254, address.contains("@"), !address.contains(" "), password.count >= (signUp ? 12 : 1), password.count <= 256 else {
            throw CalendarToolArgumentError(signUp ? "Enter a valid email and a password with at least 12 characters." : "Enter your email and password.")
        }
        guard name.count <= 100, !name.contains(where: { $0.isNewline }) else { throw CalendarToolArgumentError("Keep your name under 100 characters on one line.") }
        phase = "working"; error = nil; message = nil
        do {
            if signUp {
                switch try await client.signUp(email: address, password: password, data: name.isEmpty ? [:] : ["display_name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines))], redirectTo: Self.redirectURL) {
                case .session(let session): accept(session.user, provider: "email")
                case .user: self.email = address; phase = "verifyEmail"; message = "Check your email to confirm your account, then return to Calshot."
                }
            } else { let session = try await client.signIn(email: address, password: password); accept(session.user, provider: "email") }
        } catch { phase = "signedOut"; self.error = "Couldn’t sign in. Check your email, password and email confirmation, then try again."; throw CalendarToolArgumentError(self.error!) }
    }
    func googleSignIn() async throws {
        guard let client, !busy else { throw CalendarToolArgumentError("Wait for sign-in to finish.") }
        await refreshProviders()
        guard googleEnabled else { throw CalendarToolArgumentError("Google sign-in needs to be enabled for Calshot. You can use email while setup is completed.") }
        let providerName = "Google"
        phase = "working"; error = nil; message = "Finish \(providerName) sign-in in your browser. Calshot will reopen when you’re done."
        let attempt = generation
        webAuthentication.onReturn = { [weak self] in self?.onShowWindow?() }
        defer { onShowWindow?() }
        do {
            let session = try await client.signInWithOAuth(provider: .google, redirectTo: Self.redirectURL, scopes: "openid email profile", launchFlow: { [webAuthentication] url in
                try await webAuthentication.authenticate(url)
            })
            guard generation == attempt else { return }
            let verifiedUser = try await client.user()
            guard generation == attempt, verifiedUser.id == session.user.id else { return }
            accept(verifiedUser, provider: "google")
        } catch {
            phase = "signedOut"
            if error is CancellationError || ((error as NSError).domain == ASWebAuthenticationSessionError.errorDomain && (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue) { message = "Sign-in cancelled. You can try again whenever you’re ready."; return }
            self.error = "\(providerName) sign-in couldn’t finish. Check your connection and try again."
            throw CalendarToolArgumentError(self.error!)
        }
    }
    static let sharingRPCNames: Set<String> = ["read_calendar_sharing", "publish_calendar", "request_calendar_share", "respond_calendar_request", "manage_calendar_request", "withdraw_calendar", "calendar_publication_status", "read_shared_calendar", "search_friend_calendars"]
    func syncRPC<T: Decodable>(_ name: String, body: JSONValue, user: UUID) async throws -> T {
        guard let client, userID == user, (["read_account_state", "write_account_state", "read_mac_calendar_sync", "set_mac_calendar_sync", "write_mac_calendar_snapshot", "disable_mac_calendar_sync"].contains(name) || Self.sharingRPCNames.contains(name)) else { throw CancellationError() }
        let session = try await client.session
        guard userID == user, session.user.id == user else { throw CancellationError() }
        var request = URLRequest(url: Self.projectURL.appendingPathComponent("rest/v1/rpc/" + name))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard userID == user else { throw CancellationError() }
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        let returnsVoid = ["write_mac_calendar_snapshot", "disable_mac_calendar_sync", "respond_calendar_request", "manage_calendar_request", "withdraw_calendar", "calendar_publication_status"].contains(name)
        guard statusCode == 200 || (statusCode == 204 && returnsVoid) else {
            if Self.sharingRPCNames.contains(name) {
                let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let safe: Set<String> = ["No other verified Calshot account is available with that email. Check with your friend.", "A request for these calendars is already waiting for this friend.", "Daily request limit reached. Try again tomorrow.", "Sharing limit reached.", "This sharing setting changed. Refresh and try again.", "This request changed or expired. Refresh your requests.", "This friend is not sharing calendars with you.", "You no longer have access to this calendar.", "This calendar is no longer shared.", "A newer snapshot exists. Refresh before syncing.", "This publication changed. Refresh before syncing.", "Calendar snapshot is too large or invalid.", "Invalid event snapshot."]
                if let message = payload?["message"] as? String, safe.contains(message) { throw CalendarToolArgumentError(message) }
                throw CalendarToolArgumentError(statusCode == 401 || statusCode == 403 ? "Your Calshot session couldn’t authorize sharing. Sign in again and retry." : "Sharing couldn’t finish. Refresh Friends & sharing and try again. Your original calendars are unchanged.")
            }
            if name.contains("mac_calendar") {
                let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let safeMessages = [
                    "Invalid all-day dates.": "Calshot couldn’t read an all-day date in this calendar. Other calendars can still sync.",
                    "Invalid calendar event.": "Calshot couldn’t read one of this calendar’s events. Other calendars can still sync.",
                    "Calendar selection changed. Refresh before syncing.": "This calendar’s sync choice changed. Refresh web sync to load the latest selection.",
                    "Calendar snapshot is incomplete or too large.": "This calendar exceeds the web sync limit. Previously synced data is kept."]
                let message = safeMessages[payload?["message"] as? String ?? ""] ?? (statusCode == 401 || statusCode == 403 ? "Your Calshot session couldn’t authorize calendar sync. Sign in again and retry." : "Calendar sync couldn’t reach your account. Check your connection and retry.")
                throw CalendarToolArgumentError(message)
            }
            throw CalendarToolArgumentError("Account sync couldn’t finish. Your local data is kept. Check your connection and sync again; another device may have updated your account.")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data.isEmpty && returnsVoid ? Data("null".utf8) : data)
    }
    func verify(code: String) async throws {
        guard let client, !busy, !email.isEmpty, code.count >= 6, code.count <= 12, code.allSatisfy(\.isNumber) else { throw CalendarToolArgumentError("Enter the confirmation code from your email.") }
        phase = "working"; error = nil
        do {
            if case .session(let session) = try await client.verifyOTP(email: email, token: code, type: .signup) { accept(session.user, provider: "email") }
            else { phase = "verifyEmail" }
        } catch { phase = "verifyEmail"; self.error = "That confirmation code couldn’t be verified. Request a new email and try again."; throw CalendarToolArgumentError(self.error!) }
    }
    func resendConfirmation() async throws {
        guard let client, !busy, !email.isEmpty else { throw CalendarToolArgumentError("Enter your email first.") }
        try await client.resend(email: email, type: .signup, emailRedirectTo: Self.redirectURL)
        message = "Confirmation email requested. Check your inbox and spam folder."
    }
    func forgotPassword(email: String) async throws {
        guard let client, !busy, email.contains("@"), email.count <= 254 else { throw CalendarToolArgumentError("Enter your email first.") }
        try await client.resetPasswordForEmail(email, redirectTo: Self.redirectURL)
        message = "If an account exists for this email, you’ll receive a password reset link. Open it on this Mac."
    }
    func changePassword(_ password: String) async throws {
        guard let client, phase == "passwordRecovery", password.count >= 12, password.count <= 256 else { throw CalendarToolArgumentError("Use at least 12 characters for your new password.") }
        _ = try await client.update(user: .init(password: password))
        phase = "signedIn"; message = "Password updated."
    }
    func handleCallback(_ url: URL) async {
        guard AccountWebAuthentication.isCallback(url) else { return }
        // The live browser attempt owns code exchange; AppDelegate and the
        // AuthenticationServices completion can both deliver the same callback.
        if webAuthentication.receive(url) || webAuthentication.lastCallback == url { return }
        guard let client, url.fragment == nil,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "code" && !($0.value ?? "").isEmpty }) == true else { return }
        do { let session = try await client.session(from: url); let recovery = phase == "passwordRecovery"; accept(session.user, provider: "email"); if recovery { phase = "passwordRecovery" } }
        catch { self.error = "This sign-in link couldn’t be verified. Request a new email from this Mac."; phase = "signedOut" }
    }
    func finishOnboarding() {
        guard let userID else { return }
        preferences.set(true, forKey: "calshot.onboarded.\(userID.uuidString)"); onboarded = true
    }
    func signOut() async throws {
        guard let client, !busy else { throw CalendarToolArgumentError("Wait for sign-in to finish.") }
        generation = UUID()
        try await client.signOut(scope: .local)
        userID = nil; email = ""; onboarded = false; aiSetupConfirmed = false; identityProviders = []; signInProvider = "email"; phase = "signedOut"; error = nil; message = nil
    }
    var snapshot: JSONValue {
        var fields: [String: JSONValue] = ["required": .bool(enabled), "signedIn": .bool(userID != nil), "phase": .string(phase),
            "busy": .bool(busy), "googleEnabled": .bool(googleEnabled), "onboarded": .bool(onboarded),
            "signInProvider": .string(signInProvider), "identityProviders": .array(identityProviders.map(JSONValue.string)), "aiSetupConfirmed": .bool(aiSetupConfirmed)]
        if !email.isEmpty { fields["email"] = .string(email) }
        if let userID { fields["userID"] = .string(userID.uuidString) }
        if let message { fields["message"] = .string(message) }
        if let error { fields["error"] = .string(error) }
        return .object(fields)
    }
}

/// Own the macOS browser session. AuthenticationServices may complete on a worker
/// queue, so the callback is created outside actor isolation and explicitly hops
/// to MainActor before touching AppKit, session state, or the continuation.
@MainActor
final class AccountWebAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    typealias Completion = @Sendable (URL?, Error?) -> Void
    struct Session {
        let start: @MainActor () -> Bool
        let cancel: @MainActor () -> Void
    }
    typealias Factory = @MainActor (URL, String, any ASWebAuthenticationPresentationContextProviding, @escaping Completion) -> Session
    private let factory: Factory
    private var session: Session?
    private var continuation: CheckedContinuation<URL, Error>?
    private var attemptID: UUID?
    private(set) var lastCallback: URL?
    var isRunning: Bool { attemptID != nil }
    var onReturn: (() -> Void)?

    init(factory: @escaping Factory = AccountWebAuthentication.makeSession) { self.factory = factory }
    private static func makeSession(url: URL, scheme: String, context: any ASWebAuthenticationPresentationContextProviding, completion: @escaping Completion) -> Session {
        let native = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme, completionHandler: completion)
        native.presentationContextProvider = context
        return Session(start: { native.start() }, cancel: { native.cancel() })
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first(where: { $0.title == "Calshot" }) ?? ASPresentationAnchor()
    }
    nonisolated private static func completion(owner: AccountWebAuthentication, id: UUID) -> Completion {
        return { [weak owner] url, error in
            Task { @MainActor in owner?.finish(id: id, url: url, error: error) }
        }
    }
    static func isCallback(_ url: URL) -> Bool {
        url.scheme == "calshot" && url.host == "auth" && url.path == "/callback" && url.user == nil && url.password == nil && url.port == nil
    }
    func authenticate(_ url: URL) async throws -> URL {
        guard !isRunning else { throw CalendarToolArgumentError("A sign-in window is already open.") }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending in
                attemptID = id; continuation = pending; lastCallback = nil
                session = factory(url, "calshot", self, Self.completion(owner: self, id: id))
                if Task.isCancelled { cancel(id: id) }
                else if session?.start() != true { finish(id: id, url: nil, error: CalendarToolArgumentError("Couldn’t open Google sign-in. Try again.")) }
            }
        } onCancel: { Task { @MainActor in self.cancel(id: id) } }
    }
    @discardableResult func receive(_ url: URL) -> Bool {
        guard Self.isCallback(url), let id = attemptID else { return false }
        finish(id: id, url: url, error: nil)
        return true
    }
    private func cancel(id: UUID) {
        guard attemptID == id else { return }
        let active = session
        finish(id: id, url: nil, error: CancellationError())
        active?.cancel()
    }
    private func finish(id: UUID, url: URL?, error: Error?) {
        guard attemptID == id, let pending = continuation else { return }
        attemptID = nil; continuation = nil; session = nil
        onReturn?()
        if let error { pending.resume(throwing: error) }
        else if let url, Self.isCallback(url) { lastCallback = url; pending.resume(returning: url) }
        else { pending.resume(throwing: CalendarToolArgumentError("The sign-in response could not return to Calshot. Try again.")) }
    }
}
