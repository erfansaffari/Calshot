import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// OpenAI's local Sign in with ChatGPT flow. Credentials never leave this Mac
/// except for requests to OpenAI's authorization and Responses endpoints.
actor ChatGPTConnection {
    static let shared = ChatGPTConnection()
    private(set) var modelAvailabilityError: String?

    struct ModelOption: Identifiable, Equatable, Sendable {
        let slug: String
        let displayName: String
        var id: String { slug }
    }

    struct UsageRecord: Codable, Identifiable, Sendable {
        var id = UUID()
        let date: Date
        var model: String
        var requestCount: Int = 1
        var inputTokens: Int
        var outputTokens: Int
    }

    struct Account: Codable {
        let clientID: String
        let subject: String
        let email: String
        let idToken: String
        let accessToken: String
        let refreshToken: String
        let scopes: String
        let expiresAt: Date
        let model: String

        var canUsePlan: Bool { scopes.split(separator: " ").contains("chatgpt.tokens.use.direct") }
    }

    enum ConnectionError: LocalizedError {
        case invalidCallback, denied, invalidToken, noPlanPermission, noModel, notConnected
        case server(String)

        var errorDescription: String? {
            switch self {
            case .invalidCallback: "ChatGPT sign-in did not return a valid authorization. Try again."
            case .denied: "ChatGPT sign-in was cancelled or permission was declined."
            case .invalidToken: "Could not verify the ChatGPT identity. Try signing in again."
            case .noPlanPermission: "ChatGPT connected, but plan usage was not approved. Reconnect and allow plan usage."
            case .noModel: "This ChatGPT account has no available model for image analysis."
            case .notConnected: "Connect your ChatGPT account in Settings first."
            case .server(let message): message
            }
        }
    }

    nonisolated static func savedAccount() -> Account? {
        guard let data = try? Keychain.load() else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    func connect() async throws -> Account {
        let previous = Self.savedAccount()
        let callback = try await LoopbackCallback.start()
        defer { Task { await callback.stop() } }
        let redirectURI = await callback.redirectURI

        let state = randomURLToken()
        let nonce = randomURLToken()
        let verifier = randomURLToken()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let hostID = Self.hostID()
        let clientID = previous?.clientID ?? "dynamic_agent_client"
        var parameters = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"),
            URLQueryItem(name: "resource", value: "https://api.openai.com/v1"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "ext_agent_host_id", value: hostID)
        ]
        if let previous {
            parameters.append(URLQueryItem(name: "id_token_hint", value: previous.idToken))
            parameters.append(URLQueryItem(name: "login_hint", value: previous.email))
        } else {
            parameters.append(URLQueryItem(name: "agent_name_hint", value: "Calshot"))
        }
        var authorization = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        authorization.queryItems = parameters
        guard let url = authorization.url,
              await MainActor.run(body: { NSWorkspace.shared.open(url) }) else {
            throw ConnectionError.server("Could not open the browser for ChatGPT sign-in.")
        }

        let returned = try await withTaskCancellationHandler {
            try await callback.receive()
        } onCancel: {
            Task { await callback.cancel() }
        }
        guard returned.queryItems?.first(where: { $0.name == "state" })?.value == state else {
            throw ConnectionError.invalidCallback
        }
        if returned.queryItems?.contains(where: { $0.name == "error" }) == true { throw ConnectionError.denied }
        guard let code = returned.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw ConnectionError.invalidCallback
        }
        let issuedID = returned.queryItems?.first(where: { $0.name == "client_id" })?.value
        let exchangeID: String
        if let previous {
            guard issuedID == nil || issuedID == previous.clientID else { throw ConnectionError.invalidCallback }
            exchangeID = previous.clientID
        } else {
            guard let issuedID, issuedID.hasPrefix("oaiapp_") else { throw ConnectionError.invalidCallback }
            exchangeID = issuedID
        }
        let token = try await exchange([
            "grant_type": "authorization_code", "client_id": exchangeID,
            "code": code, "code_verifier": verifier,
            "redirect_uri": redirectURI, "resource": "https://api.openai.com/v1"
        ])
        let identity = try await verifyIDToken(token.idToken, clientID: exchangeID, nonce: nonce)
        guard let idToken = token.idToken else { throw ConnectionError.invalidToken }
        if let previous, identity.subject != previous.subject { throw ConnectionError.invalidToken }
        let scopes = token.scope
        let account = Account(clientID: exchangeID, subject: identity.subject,
                              email: identity.email, idToken: idToken,
                              accessToken: token.accessToken, refreshToken: token.refreshToken,
                              scopes: scopes, expiresAt: .now.addingTimeInterval(TimeInterval(token.expiresIn)),
                              model: "")
        let result = try await Self.finishSignIn(account, persist: { try Keychain.save(JSONEncoder().encode($0)) },
                                              loadModel: { try await self.chooseModel(accessToken: token.accessToken) })
        modelAvailabilityError = result.error
        return result.account
    }

    nonisolated static func finishSignIn(_ account: Account, persist: (Account) throws -> Void,
                                        loadModel: () async throws -> String) async throws -> (account: Account, error: String?) {
        // OAuth success must survive a temporary failure of the inference catalog.
        try persist(account)
        guard account.canUsePlan else { return (account, nil) }
        let selected: String
        do { selected = try await loadModel() }
        catch { return (account, "ChatGPT sign-in completed, but plan models are unavailable: \(error.localizedDescription)") }
        let ready = withModel(account, selected)
        try persist(ready)
        return (ready, nil)
    }

    func access() async throws -> (token: String, model: String) {
        guard var account = Self.savedAccount() else { throw ConnectionError.notConnected }
        guard account.canUsePlan else { throw ConnectionError.noPlanPermission }
        if account.expiresAt.timeIntervalSinceNow < 120 {
            let refreshed = try await exchange([
                "grant_type": "refresh_token", "client_id": account.clientID,
                "refresh_token": account.refreshToken, "resource": "https://api.openai.com/v1"
            ])
            account = Account(clientID: account.clientID, subject: account.subject,
                              email: account.email, idToken: account.idToken,
                              accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken,
                              scopes: refreshed.scope.isEmpty ? account.scopes : refreshed.scope,
                              expiresAt: .now.addingTimeInterval(TimeInterval(refreshed.expiresIn)),
                              model: account.model)
            try Keychain.save(JSONEncoder().encode(account))
        }
        if account.model.isEmpty {
            let selected = try await chooseModel(accessToken: account.accessToken)
            account = Self.withModel(account, selected)
            try Keychain.save(JSONEncoder().encode(account))
        }
        return (account.accessToken, account.model)
    }

    nonisolated private static func withModel(_ account: Account, _ model: String) -> Account {
        Account(clientID: account.clientID, subject: account.subject, email: account.email, idToken: account.idToken,
                accessToken: account.accessToken, refreshToken: account.refreshToken, scopes: account.scopes,
                expiresAt: account.expiresAt, model: model)
    }

    func refreshPreferredModel() async throws -> Account {
        let access = try await access()
        let models = try await fetchModels(accessToken: access.token)
        let selectedModel = models.contains(where: { $0.slug == access.model })
            ? access.model
            : models.first(where: { $0.slug == "gpt-5.6-luna" })?.slug ?? models.first?.slug ?? ""
        guard let account = Self.savedAccount() else { throw ConnectionError.notConnected }
        guard selectedModel != account.model else { return account }
        let updated = Account(clientID: account.clientID, subject: account.subject,
                              email: account.email, idToken: account.idToken,
                              accessToken: account.accessToken, refreshToken: account.refreshToken,
                              scopes: account.scopes, expiresAt: account.expiresAt, model: selectedModel)
        try Keychain.save(JSONEncoder().encode(updated))
        return updated
    }

    func availableModels() async throws -> [ModelOption] {
        let access = try await access()
        return try await fetchModels(accessToken: access.token)
    }

    func selectModel(_ slug: String) async throws -> Account {
        let access = try await access()
        let models = try await fetchModels(accessToken: access.token)
        guard models.contains(where: { $0.slug == slug }),
              let account = Self.savedAccount() else { throw ConnectionError.noModel }
        let updated = Account(clientID: account.clientID, subject: account.subject,
                              email: account.email, idToken: account.idToken,
                              accessToken: account.accessToken, refreshToken: account.refreshToken,
                              scopes: account.scopes, expiresAt: account.expiresAt, model: slug)
        try Keychain.save(JSONEncoder().encode(updated))
        return updated
    }

    func disconnect() async throws {
        guard let account = Self.savedAccount() else { return }
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData(["token": account.refreshToken,
                                     "token_type_hint": "refresh_token", "client_id": account.clientID])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ConnectionError.server("Could not confirm remote disconnect. You can also disconnect Calshot in ChatGPT Settings.")
            }
        } catch {
            try Keychain.delete()
            throw error
        }
        try Keychain.delete()
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let idToken: String?
        let scope: String
        let expiresIn: Int
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token"
            case idToken = "id_token", scope, expiresIn = "expires_in"
        }
    }

    private func exchange(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectionError.server("ChatGPT sign-in returned an invalid response.") }
        guard http.statusCode == 200 else {
            throw ConnectionError.server(ResponsesCalendarAgentClient.failureMessage(http: http, data: data))
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func chooseModel(accessToken: String) async throws -> String {
        let models = try await fetchModels(accessToken: accessToken)
        guard let selected = ["gpt-5.6-luna", "gpt-6-luna", "gpt-5.6-terra", "gpt-5.6-sol", "gpt-6-astra"]
            .first(where: { slug in models.contains(where: { $0.slug == slug }) }) ?? models.first?.slug else {
            throw ConnectionError.noModel
        }
        return selected
    }

    private func fetchModels(accessToken: String) async throws -> [ModelOption] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectionError.noModel }
        guard http.statusCode == 200 else {
            throw ConnectionError.server(ResponsesCalendarAgentClient.failureMessage(http: http, data: data))
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = object?["models"] as? [[String: Any]] ?? []
        let listed = models.filter { ($0["visibility"] as? String ?? "list") == "list" }
        let options = listed.compactMap { item -> ModelOption? in
            guard let slug = item["slug"] as? String else { return nil }
            return ModelOption(slug: slug, displayName: item["display_name"] as? String ?? slug)
        }
        guard !options.isEmpty else { throw ConnectionError.noModel }
        return options
    }

    private struct Identity { let subject: String; let email: String }

    private func verifyIDToken(_ token: String?, clientID: String, nonce: String) async throws -> Identity {
        guard let token else { throw ConnectionError.invalidToken }
        let segments = token.split(separator: ".")
        guard segments.count == 3,
              let headerData = Data(base64URL: String(segments[0])),
              let bodyData = Data(base64URL: String(segments[1])),
              let signature = Data(base64URL: String(segments[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String else {
            throw ConnectionError.invalidToken
        }
        let (jwksData, jwksResponse) = try await URLSession.shared.data(from: URL(string: "https://auth.openai.com/.well-known/jwks.json")!)
        guard (jwksResponse as? HTTPURLResponse)?.statusCode == 200,
              let jwks = try JSONSerialization.jsonObject(with: jwksData) as? [String: Any],
              let keys = jwks["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              let modulus = (key["n"] as? String).flatMap({ Data(base64URL: $0) }),
              let exponent = (key["e"] as? String).flatMap({ Data(base64URL: $0) }) else {
            throw ConnectionError.invalidToken
        }
        let publicKeyData = derSequence(derInteger(modulus) + derInteger(exponent))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                                         kSecAttrKeySizeInBits as String: modulus.count * 8]
        guard let publicKey = SecKeyCreateWithData(publicKeyData as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data("\(segments[0]).\(segments[1])".utf8) as CFData,
                                    signature as CFData, nil),
              claims["iss"] as? String == "https://auth.openai.com",
              claims["nonce"] as? String == nonce,
              let exp = claims["exp"] as? Double, exp > Date().timeIntervalSince1970,
              let subject = claims["sub"] as? String, !subject.isEmpty else {
            throw ConnectionError.invalidToken
        }
        let audience = claims["aud"] as? String
        let audiences = claims["aud"] as? [String] ?? []
        guard audience == clientID || audiences.contains(clientID) else { throw ConnectionError.invalidToken }
        return Identity(subject: subject, email: claims["email"] as? String ?? "ChatGPT account")
    }

    private static func hostID() -> String {
        let key = "chatGPTHostID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let value = "urn:uuid:\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private func randomURLToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    private func formData(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

private enum Keychain {
    private static let service = "com.calshot.chatgpt"
    private static let account = "connection"

    static func load() throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ChatGPTConnection.ConnectionError.server("Could not read ChatGPT connection from Keychain.")
        }
        return data
    }

    static func save(_ data: Data) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        let changes: [String: Any] = [kSecValueData as String: data,
                                      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            changes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw ChatGPTConnection.ConnectionError.server("Could not save ChatGPT connection in Keychain.")
            }
        } else if status != errSecSuccess {
            throw ChatGPTConnection.ConnectionError.server("Could not update ChatGPT connection in Keychain.")
        }
    }

    static func delete() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ChatGPTConnection.ConnectionError.server("Could not remove ChatGPT connection from Keychain.")
        }
    }
}

@MainActor
final class LoopbackCallback {
    private let listener: NWListener
    private var continuation: CheckedContinuation<URLComponents, Error>?
    private var received: URLComponents?
    private var timeout: Task<Void, Never>?
    private var wasCancelled = false
    var redirectURI: String { "http://127.0.0.1:\(listener.port!.rawValue)/auth/callback" }

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func start() async throws -> LoopbackCallback {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let callback = LoopbackCallback(listener: listener)
        listener.newConnectionHandler = { connection in
            Task { @MainActor in callback.handle(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .main)
        }
        return callback
    }

    func receive() async throws -> URLComponents {
        if wasCancelled { throw CancellationError() }
        if let received { return received }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 180_000_000_000) }
                catch { return }
                self?.continuation?.resume(throwing: ChatGPTConnection.ConnectionError.server("Sign-in timed out."))
                self?.continuation = nil
            }
        }
    }

    func cancel() {
        wasCancelled = true
        timeout?.cancel()
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: CancellationError())
        }
        listener.cancel()
    }

    func stop() { cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let target = request.split(separator: " ").dropFirst().first,
                  target.hasPrefix("/auth/callback?"),
                  let components = URLComponents(string: "http://127.0.0.1\(target)") else {
                connection.cancel()
                return
            }
            let page = "<html><body style='font-family:system-ui;text-align:center;padding:5rem;background:#111;color:white'><h2>Return to Calshot</h2><p>You can close this tab.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            Task { @MainActor in self.deliver(components) }
        }
    }

    private func deliver(_ components: URLComponents) {
        guard !wasCancelled else { return }
        timeout?.cancel()
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: components)
        } else {
            received = components
        }
    }
}

private extension Data {
    var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }

    init?(base64URL: String) {
        let value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
}

private func derLength(_ count: Int) -> Data {
    if count < 128 { return Data([UInt8(count)]) }
    if count < 256 { return Data([0x81, UInt8(count)]) }
    return Data([0x82, UInt8((count >> 8) & 0xff), UInt8(count & 0xff)])
}

private func derInteger(_ value: Data) -> Data {
    let bytes = value.first.map { $0 >= 0x80 } == true ? Data([0]) + value : value
    return Data([0x02]) + derLength(bytes.count) + bytes
}

private func derSequence(_ value: Data) -> Data {
    Data([0x30]) + derLength(value.count) + value
}
