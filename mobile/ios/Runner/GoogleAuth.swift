import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// Google account for "Đồng bộ Google Drive" on iOS: OAuth 2.0 for native apps (the system
/// browser sheet with PKCE), the refresh token kept in the Keychain. Two scopes only: the e-mail
/// address and the app's own hidden folder on Drive. The OAuth client is an "iOS" client of the
/// Google Cloud project; its id comes from Dart (GOOGLE_IOS_CLIENT_ID). Counterpart of GoogleAuth.kt.
final class GoogleAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum AuthError: Error {
        case notConfigured
        case network(String)
        case google(String)
    }

    static let scopes = "email https://www.googleapis.com/auth/drive.appdata"
    private static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    private let anchor: () -> ASPresentationAnchor?
    private var session: ASWebAuthenticationSession?

    init(anchor: @escaping () -> ASPresentationAnchor?) {
        self.anchor = anchor
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return anchor() ?? ASPresentationAnchor()
    }

    /// Answers {accessToken, expiresIn}, or nil when the user cancelled or, for a silent request,
    /// when there is no usable grant. Completes on the main thread.
    func authorize(
        interactive: Bool, clientId: String, completion: @escaping (Result<[String: Any]?, AuthError>) -> Void
    ) {
        guard GoogleAuth.redirectScheme(clientId: clientId) != nil else { return completion(.failure(.notConfigured)) }
        if interactive {
            return startBrowser(clientId: clientId, completion: completion)
        }
        guard let refresh = Keychain.read() else { return completion(.success(nil)) }
        post(GoogleAuth.tokenEndpoint, form: [
            "refresh_token": refresh,
            "client_id": clientId,
            "grant_type": "refresh_token",
        ]) { result in
            switch result {
            case .success(let json):
                guard let access = json["access_token"] as? String else {
                    return completion(.failure(.google("no access token")))
                }
                completion(.success(GoogleAuth.payload(access: access, json: json)))
            case .failure(.google(let code)) where code == "invalid_grant":
                // Revoked or expired: the user has to sign in again.
                Keychain.delete()
                completion(.success(nil))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Forgets the stored grant on this device. It is not revoked at Google: the user's other
    /// devices share it and would all be signed out.
    func signOut(completion: @escaping () -> Void) {
        Keychain.delete()
        completion()
    }

    private func startBrowser(clientId: String, completion: @escaping (Result<[String: Any]?, AuthError>) -> Void) {
        guard let scheme = GoogleAuth.redirectScheme(clientId: clientId) else { return completion(.failure(.notConfigured)) }
        let redirect = "\(scheme):/oauth2redirect"
        let verifier = GoogleAuth.codeVerifier()
        let state = UUID().uuidString
        guard let url = GoogleAuth.authorizationURL(clientId: clientId, redirect: redirect, verifier: verifier, state: state)
        else { return completion(.failure(.notConfigured)) }
        session?.cancel()
        let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
            DispatchQueue.main.async {
                self.session = nil
                if let error = error {
                    if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                        return completion(.success(nil))
                    }
                    return completion(.failure(.google(error.localizedDescription)))
                }
                let items = callback.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
                let value = { (name: String) in items.first(where: { $0.name == name })?.value }
                if let failure = value("error") {
                    // "access_denied": the user said no on the consent screen.
                    return completion(failure == "access_denied" ? .success(nil) : .failure(.google(failure)))
                }
                guard value("state") == state, let code = value("code") else {
                    return completion(.failure(.google("unexpected redirect")))
                }
                self.exchange(code: code, verifier: verifier, redirect: redirect, clientId: clientId, completion: completion)
            }
        }
        browser.presentationContextProvider = self
        // Reuse the Google session of Safari: no password to type when already signed in there.
        browser.prefersEphemeralWebBrowserSession = false
        session = browser
        if !browser.start() {
            session = nil
            completion(.failure(.google("cannot open the sign-in page")))
        }
    }

    private func exchange(
        code: String, verifier: String, redirect: String, clientId: String,
        completion: @escaping (Result<[String: Any]?, AuthError>) -> Void
    ) {
        post(GoogleAuth.tokenEndpoint, form: [
            "code": code,
            "client_id": clientId,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]) { result in
            switch result {
            case .success(let json):
                guard let access = json["access_token"] as? String else {
                    return completion(.failure(.google("no access token")))
                }
                if let refresh = json["refresh_token"] as? String { Keychain.write(refresh) }
                completion(.success(GoogleAuth.payload(access: access, json: json)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// POSTs a form and answers its JSON body, on the main thread.
    private func post(_ url: URL, form: [String: String], completion: @escaping (Result<[String: Any], AuthError>) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleAuth.formBody(form).data(using: .utf8)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<[String: Any], AuthError>
            if let error = error {
                result = .failure(.network(error.localizedDescription))
            } else {
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) {
                    result = .success(json)
                } else {
                    result = .failure(.google(json["error"] as? String ?? "http_\(status)"))
                }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // MARK: - Pure helpers (unit tested)

    static func payload(access: String, json: [String: Any]) -> [String: Any] {
        var payload: [String: Any] = ["accessToken": access]
        if let seconds = (json["expires_in"] as? NSNumber)?.intValue { payload["expiresIn"] = seconds }
        return payload
    }

    /// "1234-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.1234-abc", the redirect
    /// scheme Google gives every iOS client.
    static func redirectScheme(clientId: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientId.hasSuffix(suffix) else { return nil }
        let id = String(clientId.dropLast(suffix.count))
        guard !id.isEmpty, !id.contains("/"), !id.contains(":") else { return nil }
        return "com.googleusercontent.apps.\(id)"
    }

    static func authorizationURL(clientId: String, redirect: String, verifier: String, state: String) -> URL? {
        var components = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Account choice every time; consent so that a refresh token is issued again.
            URLQueryItem(name: "prompt", value: "select_account consent"),
        ]
        return components?.url
    }

    /// RFC 7636: 32 random bytes, base64url without padding (43 characters).
    static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return base64url(Data(bytes))
    }

    static func codeChallenge(_ verifier: String) -> String {
        return base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formBody(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }
}

/// The refresh token, readable after the first unlock (sync can run from a notification tap).
enum Keychain {
    private static let service = "vn.timnhac.google"
    private static let account = "refresh_token"

    private static var base: [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        delete()
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}
