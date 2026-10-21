import AppKit
import CryptoKit
import Foundation
import Security

/// Provider credentials are isolated from model requests and stored only in Keychain.
actor CalendarAccountConnection {
    static let shared = CalendarAccountConnection()
    nonisolated static let googleClientID = "1055723898367-drt4ubelrd42462qdnfgovcgkcotg0r4.apps.googleusercontent.com"
    enum Provider: String, Codable, CaseIterable, Sendable { case google, outlook, icloud
        var title: String { switch self { case .google: "Google"; case .outlook: "Outlook / Microsoft 365"; case .icloud: "Apple iCloud" } }
        var authorizeURL: String { self == .google ? "https://accounts.google.com/o/oauth2/v2/auth" : "https://login.microsoftonline.com/common/oauth2/v2.0/authorize" }
        var tokenURL: String { self == .google ? "https://oauth2.googleapis.com/token" : "https://login.microsoftonline.com/common/oauth2/v2.0/token" }
        var scopes: String { self == .google ? "openid email https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly" : "openid email profile offline_access User.Read Calendars.ReadWrite" }
    }
    struct Account: Codable, Identifiable, Sendable {
        var id: UUID
        var provider: Provider
        var email: String
        var subject: String
        var clientID: String
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var calDAVHomeURL: String? = nil
    }
    struct ConnectionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private func currentAccounts() throws -> [Account] { try JSONDecoder().decode([Account].self, from: Self.credentialData()) }
    private var googleTokenExchange: (@Sendable ([String: String]) async throws -> Data)?
    func configureGoogleTokenExchange(_ exchange: @escaping @Sendable ([String: String]) async throws -> Data) { googleTokenExchange = exchange }
    private var refreshes: [UUID: Task<Account, Error>] = [:]
    nonisolated static func accounts() -> [Account] { (try? JSONDecoder().decode([Account].self, from: credentialData())) ?? [] }
    nonisolated private static func credentialData() throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.calshot.calendar-accounts", kSecAttrAccount as String: "accounts", kSecReturnData as String: true]
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return Data("[]".utf8) }
        guard result == errSecSuccess, let data = item as? Data else { throw ConnectionError(message: "Could not read calendar credentials from Keychain.") }
        return data
    }
    private func persist(_ accounts: [Account]) throws {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.calshot.calendar-accounts", kSecAttrAccount as String: "accounts"]
        let data = try JSONEncoder().encode(accounts)
        let updated = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var item = key; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ConnectionError(message: "Could not store calendar credentials in Keychain.") }; return
        }
        guard updated == errSecSuccess else { throw ConnectionError(message: "Could not update calendar credentials in Keychain.") }
    }
    nonisolated static func googleClientSecret(clientID: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.calshot.google-oauth-client", kSecAttrAccount as String: clientID, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    nonisolated static func saveGoogleClientSecret(_ secret: String, clientID: String) throws {
        guard !clientID.isEmpty, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConnectionError(message: "Enter the desktop client ID and client secret.") }
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.calshot.google-oauth-client", kSecAttrAccount as String: clientID]
        let data = Data(secret.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let status = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = key; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ConnectionError(message: "Could not save Google configuration in Keychain.") }; return
        }
        guard status == errSecSuccess else { throw ConnectionError(message: "Could not update Google configuration in Keychain.") }
    }
    func connect(provider: Provider, clientID: String) async throws -> Account {
        guard provider != .icloud else { throw ConnectionError(message: "iCloud uses an app-specific password, not OAuth.") }
        guard !clientID.trimmingCharacters(in: .whitespaces).isEmpty else { throw ConnectionError(message: "Register Calshot's desktop OAuth client first and enter its client ID.") }
        if provider == .google, clientID == Self.googleClientID, googleTokenExchange == nil { throw ConnectionError(message: "Google Calendar is getting ready. Try connecting again in a moment.") }
        let callback = try await LoopbackCallback.start()
        defer { Task { await callback.stop() } }
        let loopbackRedirect = await callback.redirectURI
        let redirect = provider == .outlook ? loopbackRedirect.replacingOccurrences(of: "127.0.0.1", with: "localhost") : loopbackRedirect
        let state = try Self.randomToken(), verifier = try Self.randomToken()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: provider.authorizeURL)!
        var parameters = ["client_id": clientID, "redirect_uri": redirect, "response_type": "code", "scope": provider.scopes,
                          "state": state, "code_challenge": challenge, "code_challenge_method": "S256"]
        if provider == .google { parameters["access_type"] = "offline"; parameters["prompt"] = "consent select_account" }
        else { parameters["prompt"] = "select_account" }
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url, await MainActor.run(body: { NSWorkspace.shared.open(url) }) else { throw ConnectionError(message: "Could not open the account sign-in page.") }
        let returned = try await withTaskCancellationHandler { try await callback.receive() } onCancel: { Task { await callback.cancel() } }
        guard returned.queryItems?.first(where: { $0.name == "state" })?.value == state else { throw ConnectionError(message: "The sign-in response did not match this connection attempt.") }
        if let error = returned.queryItems?.first(where: { $0.name == "error" })?.value {
            let detail = returned.queryItems?.first(where: { $0.name == "error_description" })?.value ?? "Calendar access was cancelled or denied."
            throw ConnectionError(message: "\(provider.title) sign-in failed (\(error)): \(String(detail.prefix(1500)))")
        }
        guard let code = returned.queryItems?.first(where: { $0.name == "code" })?.value else { throw ConnectionError(message: "Sign-in returned no authorization code.") }
        let tokens = try await token(provider: provider, fields: ["grant_type": "authorization_code", "client_id": clientID, "redirect_uri": redirect, "code": code, "code_verifier": verifier])
        if let scope = tokens.scope, !Self.hasCalendarScopes(provider: provider, scope: scope) {
            throw ConnectionError(message: "Calendar access was not fully granted. Existing macOS connections remain available; reconnect and approve the requested calendar permissions.")
        }
        let identityURL = provider == .google ? "https://openidconnect.googleapis.com/v1/userinfo" : "https://graph.microsoft.com/v1.0/me?$select=id,mail,userPrincipalName"
        var request = URLRequest(url: URL(string: identityURL)!); request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let identity = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = identity[provider == .google ? "sub" : "id"] as? String else { throw ConnectionError(message: "Could not verify the connected calendar account.") }
        let email = identity["email"] as? String ?? identity["mail"] as? String ?? identity["userPrincipalName"] as? String ?? provider.title
        var accounts = try currentAccounts()
        let old = accounts.first { $0.provider == provider && $0.subject == subject }
        let account = Account(id: old?.id ?? UUID(), provider: provider, email: email, subject: subject, clientID: clientID,
            accessToken: tokens.accessToken, refreshToken: tokens.refreshToken ?? old?.refreshToken ?? "", expiresAt: .now.addingTimeInterval(tokens.expiresIn))
        guard !account.refreshToken.isEmpty else { throw ConnectionError(message: "No offline access was granted. Reconnect and approve calendar access.") }
        try Task.checkCancellation()
        accounts.removeAll { $0.id == account.id }; accounts.append(account); try persist(accounts)
        return account
    }
    func connectICloud(email: String, appPassword: String) async throws -> Account {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), appPassword.range(of: #"^[a-zA-Z]{4}(-[a-zA-Z]{4}){3}$"#, options: .regularExpression) != nil else {
            throw ConnectionError(message: "Enter your Apple Account email and an app-specific password in xxxx-xxxx-xxxx-xxxx format. Do not use your Apple Account password.")
        }
        let home = try await ICloudCalendarService.discover(email: email, password: appPassword)
        var accounts = try currentAccounts()
        let existing = accounts.first { $0.provider == .icloud && $0.email.lowercased() == email.lowercased() }
        var account = Account(id: existing?.id ?? UUID(), provider: .icloud, email: email, subject: email.lowercased(), clientID: "", accessToken: appPassword, refreshToken: "", expiresAt: .distantFuture)
        account.calDAVHomeURL = home.absoluteString
        accounts.removeAll { $0.id == account.id }; accounts.append(account); try persist(accounts)
        return account
    }
    func access(accountID: UUID) async throws -> Account {
        guard let account = try currentAccounts().first(where: { $0.id == accountID }) else { throw ConnectionError(message: "The calendar account is disconnected.") }
        if account.expiresAt.timeIntervalSinceNow > 120 { return account }
        if let refreshing = refreshes[accountID] { return try await refreshing.value }
        let refreshing = Task { try await self.refresh(account) }; refreshes[accountID] = refreshing
        defer { refreshes[accountID] = nil }
        return try await refreshing.value
    }
    private func refresh(_ account: Account) async throws -> Account {
        let tokens = try await token(provider: account.provider, fields: ["grant_type": "refresh_token", "client_id": account.clientID, "refresh_token": account.refreshToken])
        var updated = account; updated.accessToken = tokens.accessToken; updated.refreshToken = tokens.refreshToken ?? account.refreshToken
        updated.expiresAt = .now.addingTimeInterval(tokens.expiresIn)
        var accounts = try currentAccounts()
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { throw ConnectionError(message: "The account was disconnected while refreshing.") }
        accounts[index] = updated; try persist(accounts); return updated
    }
    func disconnect(_ id: UUID) throws { try persist(currentAccounts().filter { $0.id != id }) }
    private struct Tokens: Decodable {
        let accessToken: String; let refreshToken: String?; let expiresIn: Double; let scope: String?
        enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", scope }
    }
    private func token(provider: Provider, fields: [String: String]) async throws -> Tokens {
        if provider == .google, fields["client_id"] == Self.googleClientID {
            guard let googleTokenExchange else { throw ConnectionError(message: "Sign in to Calshot and reconnect Google Calendar.") }
            return try JSONDecoder().decode(Tokens.self, from: await googleTokenExchange(fields))
        }
        let secret = provider == .google ? Self.googleClientSecret(clientID: fields["client_id"] ?? "") : nil
        let request = try Self.tokenRequest(provider: provider, fields: fields, clientSecret: secret)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectionError(message: "Invalid token response.") }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw ConnectionError(message: "Calendar sign-in failed (HTTP \(http.statusCode)): \(object?["error_description"] as? String ?? object?["error"] as? String ?? "Check the desktop OAuth registration.")")
        }
        return try JSONDecoder().decode(Tokens.self, from: data)
    }
    nonisolated static func tokenRequest(provider: Provider, fields: [String: String], clientSecret: String?) throws -> URLRequest {
        var fields = fields
        if provider == .google {
            guard let clientSecret, !clientSecret.isEmpty else { throw ConnectionError(message: "Google setup is incomplete. Save the desktop client secret in Connection setup.") }
            fields["client_secret"] = clientSecret
        }
        var request = URLRequest(url: URL(string: provider.tokenURL)!); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents(); body.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return request
    }
    nonisolated static func hasCalendarScopes(provider: Provider, scope: String) -> Bool {
        let scopes = Set(scope.lowercased().split(separator: " ").map(String.init))
        switch provider {
        case .google:
            return scopes.contains("https://www.googleapis.com/auth/calendar") ||
                (scopes.contains("https://www.googleapis.com/auth/calendar.events") && scopes.contains("https://www.googleapis.com/auth/calendar.calendarlist.readonly"))
        case .outlook: return scopes.contains("calendars.readwrite") || scopes.contains("https://graph.microsoft.com/calendars.readwrite")
        case .icloud: return false
        }
    }
    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ConnectionError(message: "Could not start a secure sign-in session.") }
        return base64URL(Data(bytes))
    }
    nonisolated static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
