// AuthManager.swift
// Handles OAuth authentication, credential loading, token refresh, and token persistence

import Foundation
import Combine

// MARK: - Credential source

enum CredentialSource: String {
    case file = "credentials.json"
    case keychain = "Keychain"
    case environment = "CLAUDE_CODE_OAUTH_TOKEN"
    case none = "Not found"
}

// MARK: - Auth manager

class AuthManager: ObservableObject {

    @Published var isAuthenticated = false
    @Published var credentialSource: CredentialSource = .none
    @Published var subscriptionType: String = ""

    private(set) var accessToken: String?
    private(set) var refreshToken: String?
    private(set) var tokenExpiresAt: Double?

    private var credentialsWatcher: DispatchSourceFileSystemObject?

    // OAuth refresh is intentionally NOT done by this app.
    // Claude Code manages the single-use refresh token cycle.
    // If we refresh, we invalidate Claude Code's token → user must re-login.

    static let credentialsPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }()

    // MARK: - Credential loading

    func loadCredentials() {
        // 1. File ~/.claude/.credentials.json
        if let data = try? Data(contentsOf: Self.credentialsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            accessToken = token
            refreshToken = oauth["refreshToken"] as? String
            tokenExpiresAt = oauth["expiresAt"] as? Double
            subscriptionType = oauth["subscriptionType"] as? String ?? ""
            credentialSource = .file
            isAuthenticated = true
            Log.info("Credentials loaded from file (type: \(subscriptionType))")
            return
        }

        // 2. Keychain — load off main thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let keychainJSON = Self.loadFromKeychain()
            DispatchQueue.main.async {
                guard let self else { return }
                if let keychainJSON,
                   let oauth = keychainJSON["claudeAiOauth"] as? [String: Any],
                   let token = oauth["accessToken"] as? String, !token.isEmpty {
                    self.accessToken = token
                    self.refreshToken = oauth["refreshToken"] as? String
                    self.tokenExpiresAt = oauth["expiresAt"] as? Double
                    self.subscriptionType = oauth["subscriptionType"] as? String ?? ""
                    self.credentialSource = .keychain
                    self.isAuthenticated = true
                    Log.info("Credentials loaded from Keychain (type: \(self.subscriptionType))")
                    return
                }

                // 3. Environment variable
                if let envToken = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"],
                   !envToken.isEmpty {
                    self.accessToken = envToken
                    self.credentialSource = .environment
                    self.isAuthenticated = true
                    Log.info("Credentials loaded from environment")
                    return
                }

                self.credentialSource = .none
                self.isAuthenticated = false
                Log.warn("No credentials found")
            }
        }
    }

    // MARK: - Token management

    var tokenNeedsRefresh: Bool {
        guard let expiresAt = tokenExpiresAt else { return true }
        let expiresDate = Date(timeIntervalSince1970: expiresAt / 1000)
        return Date().addingTimeInterval(5 * 60) >= expiresDate
    }

    var tokenExpired: Bool {
        guard let expiresAt = tokenExpiresAt else { return false }
        let expiresDate = Date(timeIntervalSince1970: expiresAt / 1000)
        return Date() >= expiresDate
    }

    /// Reload credentials from disk first, then keychain as fallback.
    /// On macOS, Claude Code may store credentials exclusively in keychain
    /// (deleting .credentials.json), so we must check both sources.
    func reloadCredentials(completion: @escaping (Bool) -> Void) {
        let previousToken = accessToken

        // 1. Try file first
        if let data = try? Data(contentsOf: Self.credentialsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            accessToken = token
            refreshToken = oauth["refreshToken"] as? String
            tokenExpiresAt = oauth["expiresAt"] as? Double
            subscriptionType = oauth["subscriptionType"] as? String ?? ""
            credentialSource = .file
            isAuthenticated = true
            let changed = accessToken != previousToken
            if changed { Log.info("Credentials reloaded from file") }
            completion(true)
            return
        }

        // 2. Fallback to keychain (off main thread)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let keychainJSON = Self.loadFromKeychain()
            DispatchQueue.main.async {
                guard let self else { return }
                if let keychainJSON,
                   let oauth = keychainJSON["claudeAiOauth"] as? [String: Any],
                   let token = oauth["accessToken"] as? String, !token.isEmpty {
                    self.accessToken = token
                    self.refreshToken = oauth["refreshToken"] as? String
                    self.tokenExpiresAt = oauth["expiresAt"] as? Double
                    self.subscriptionType = oauth["subscriptionType"] as? String ?? ""
                    self.credentialSource = .keychain
                    self.isAuthenticated = true
                    let changed = self.accessToken != previousToken
                    if changed { Log.info("Credentials reloaded from Keychain") }
                    completion(true)
                } else {
                    Log.warn("No credentials found in file or Keychain")
                    completion(self.isAuthenticated)
                }
            }
        }
    }

    // MARK: - Silent token self-refresh

    private static let oauthTokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Attempt a silent OAuth refresh_token grant.
    /// Writes the new tokens back to Keychain (and credentials file if present)
    /// so Claude Code picks up the updated refresh token on its next operation.
    func selfRefreshToken(completion: @escaping (Bool) -> Void) {
        guard let rt = refreshToken, !rt.isEmpty else {
            Log.warn("selfRefreshToken: no refresh token available")
            completion(false)
            return
        }

        Log.info("selfRefreshToken: attempting refresh_token grant")
        var request = URLRequest(url: Self.oauthTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1", forHTTPHeaderField: "User-Agent")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": rt,
            "client_id": Self.oauthClientID
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(false)
            return
        }
        request.httpBody = bodyData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                Log.error("selfRefreshToken: network error: \(error)")
                DispatchQueue.main.async { completion(false) }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String, !newAccessToken.isEmpty else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(no body)"
                Log.error("selfRefreshToken: bad response — \(body.prefix(200))")
                DispatchQueue.main.async { completion(false) }
                return
            }

            let newRefreshToken = json["refresh_token"] as? String ?? rt
            let expiresIn = json["expires_in"] as? Double ?? 3600
            let newExpiresAt = (Date().timeIntervalSince1970 + expiresIn) * 1000

            DispatchQueue.main.async {
                self.accessToken = newAccessToken
                self.refreshToken = newRefreshToken
                self.tokenExpiresAt = newExpiresAt
                self.isAuthenticated = true
                Log.info("selfRefreshToken: success — new token expires in \(Int(expiresIn))s")
                self.persistRefreshedCredentials(
                    accessToken: newAccessToken,
                    refreshToken: newRefreshToken,
                    expiresAt: newExpiresAt
                )
                completion(true)
            }
        }.resume()
    }

    /// Write refreshed tokens back to Keychain and credentials file,
    /// preserving existing fields (subscriptionType, rateLimitTier, scopes).
    private func persistRefreshedCredentials(accessToken: String, refreshToken: String, expiresAt: Double) {
        DispatchQueue.global(qos: .utility).async {
            // Read existing entry to preserve non-token fields
            var root = Self.loadFromKeychain() ?? [:]
            var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
            oauth["accessToken"] = accessToken
            oauth["refreshToken"] = refreshToken
            oauth["expiresAt"] = Int(expiresAt)
            root["claudeAiOauth"] = oauth

            guard let jsonData = try? JSONSerialization.data(withJSONObject: root),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                Log.error("persistRefreshedCredentials: failed to serialize JSON")
                return
            }

            // Overwrite Keychain entry
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["add-generic-password", "-U", "-s", "Claude Code-credentials", "-a", "", "-w", jsonString]
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                Log.info("persistRefreshedCredentials: Keychain updated")
            } else {
                Log.warn("persistRefreshedCredentials: Keychain update failed (status \(p.terminationStatus))")
            }

            // Also update credentials file if it exists
            if FileManager.default.fileExists(atPath: Self.credentialsPath.path),
               let fileData = try? Data(contentsOf: Self.credentialsPath),
               var fileJson = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any] {
                var fileOauth = fileJson["claudeAiOauth"] as? [String: Any] ?? [:]
                fileOauth["accessToken"] = accessToken
                fileOauth["refreshToken"] = refreshToken
                fileOauth["expiresAt"] = Int(expiresAt)
                fileJson["claudeAiOauth"] = fileOauth
                if let newData = try? JSONSerialization.data(withJSONObject: fileJson) {
                    try? newData.write(to: Self.credentialsPath)
                    Log.info("persistRefreshedCredentials: credentials file updated")
                }
            }
        }
    }

    // MARK: - Credentials file watcher

    func startWatchingCredentials() {
        stopWatchingCredentials()

        let path = Self.credentialsPath.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Small delay to let the file finish writing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let wasAuthenticated = self.isAuthenticated
                self.loadCredentials()
                if !wasAuthenticated && self.isAuthenticated {
                    Log.info("Credentials detected via file watcher")
                }
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        credentialsWatcher = source
    }

    private func stopWatchingCredentials() {
        credentialsWatcher?.cancel()
        credentialsWatcher = nil
    }

    deinit {
        stopWatchingCredentials()
    }

    // MARK: - Keychain

    private static func loadFromKeychain() -> [String: Any]? {
        // Anthropic recently moved from a single Keychain entry named
        // "Claude Code-credentials" to per-account sharded entries named
        // "Claude Code-credentials-<hex>". Try the legacy unsharded service
        // first (cheap, may still exist for legacy installs), then fall
        // back to enumerating and reading the sharded entries.
        if let json = readKeychainServiceAsOauthJSON("Claude Code-credentials") {
            return json
        }
        // Cache the last-known-good sharded service so subsequent launches
        // skip the enumeration step. UserDefaults is fine — it's a service
        // name string, not a credential.
        if let cached = UserDefaults.standard.string(forKey: "auth.shardedService"),
           let json = readKeychainServiceAsOauthJSON(cached) {
            return json
        }
        for service in enumerateShardedCredentialServices() {
            if let json = readKeychainServiceAsOauthJSON(service) {
                UserDefaults.standard.set(service, forKey: "auth.shardedService")
                Log.info("Auth: found OAuth payload in sharded Keychain service \(service)")
                return json
            }
        }
        return nil
    }

    /// Read a generic-password Keychain entry by service name and return its
    /// parsed JSON body, or nil if the entry is missing/empty/non-JSON or
    /// doesn't contain a `claudeAiOauth` payload.
    private static func readKeychainServiceAsOauthJSON(_ service: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let rawData = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let trimmed = String(data: rawData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  let jsonData = trimmed.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  json["claudeAiOauth"] != nil
            else { return nil }
            return json
        } catch {
            return nil
        }
    }

    /// Enumerate Keychain service names matching `Claude Code-credentials-<hex>`
    /// by parsing the metadata-only `security dump-keychain` output (no
    /// password material is read here — passwords are fetched per-service
    /// via `readKeychainServiceAsOauthJSON`).
    private static func enumerateShardedCredentialServices() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["dump-keychain"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            let pattern = #"\"svce\"<blob>=\"(Claude Code-credentials-[0-9a-f]+)\""#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(output.startIndex..., in: output)
            var found: [String] = []
            var seen: Set<String> = []
            regex.enumerateMatches(in: output, range: range) { match, _, _ in
                guard let match = match,
                      match.numberOfRanges >= 2,
                      let r = Range(match.range(at: 1), in: output) else { return }
                let svc = String(output[r])
                if !seen.contains(svc) {
                    seen.insert(svc)
                    found.append(svc)
                }
            }
            return found
        } catch {
            return []
        }
    }
}
