// CodexUsageManager.swift
//
// Personal-fork addition. Mirrors UsageManager for OpenAI's Codex CLI.
//
// Architecture parity with the Claude side:
//
//   Claude                                 Codex
//   ------------------------------------   ------------------------------------
//   ~/.claude/.credentials.json (auth)     ~/.codex/auth.json (auth)
//   api.anthropic.com/api/oauth/usage      chatgpt.com/backend-api/wham/usage
//   OAuthUsageResponse                     CodexRateLimitSnapshot list
//   5h session + 7d windows + per-model    primary (5h) + secondary (7d) windows
//
// Response schema is mirrored from openai/codex's
//   codex-rs/protocol/src/protocol.rs (RateLimitSnapshot, RateLimitWindow)
// and the URL/header conventions from
//   codex-rs/backend-client/src/client.rs (get_rate_limits_many, headers()).
//
// v1 scope: read auth file → call API → expose quotas array compatible with
// UsageQuota so the existing quota-card UI components work unmodified.
// Deferred: token refresh on 401 (user must run `codex` to refresh), JSONL
// transcript parsing for analytics, auto-refresh timer.

import Foundation
import Combine

// MARK: - auth.json model

private struct CodexAuthFile: Decodable {
    let auth_mode: String?
    let tokens: Tokens?

    struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String?
        let account_id: String?
    }
}

// MARK: - /wham/usage response model

private struct CodexRateLimitWindow: Decodable {
    let used_percent: Double
    let window_minutes: Int?
    let resets_at: Int64?
}

private struct CodexRateLimitSnapshot: Decodable {
    let limit_id: String?
    let limit_name: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
}

/// The server may return either a bare snapshot or a list. Try both shapes.
private enum CodexUsageResponse {
    case single(CodexRateLimitSnapshot)
    case list([CodexRateLimitSnapshot])

    static func decode(_ data: Data) -> CodexUsageResponse? {
        let dec = JSONDecoder()
        if let list = try? dec.decode([CodexRateLimitSnapshot].self, from: data) {
            return .list(list)
        }
        if let single = try? dec.decode(CodexRateLimitSnapshot.self, from: data) {
            return .single(single)
        }
        // Some servers wrap the list in an envelope. Try `.snapshots` and `.data`.
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["snapshots", "data", "rate_limits"] {
                if let nested = dict[key],
                   let nestedData = try? JSONSerialization.data(withJSONObject: nested) {
                    if let list = try? dec.decode([CodexRateLimitSnapshot].self, from: nestedData) {
                        return .list(list)
                    }
                    if let single = try? dec.decode(CodexRateLimitSnapshot.self, from: nestedData) {
                        return .single(single)
                    }
                }
            }
        }
        return nil
    }

    var snapshots: [CodexRateLimitSnapshot] {
        switch self {
        case .single(let s): return [s]
        case .list(let l): return l
        }
    }
}

// MARK: - Manager

final class CodexUsageManager: ObservableObject {

    // MARK: - Published state (mirrors UsageManager surface)

    @Published var quotas: [UsageQuota] = []
    @Published var isLoading: Bool = false
    @Published var isAuthenticated: Bool = false
    @Published var errorMessage: String?
    @Published var lastRefresh: Date?

    // MARK: - Config

    private static let authFilePath: String = {
        let home = ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".codex/auth.json")
    }()

    private static let chatgptUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private static let refreshInterval: TimeInterval = 120 // 2 min, matches Claude side

    private var refreshTimer: Timer?

    init() {
        refresh()
        scheduleAutoRefresh()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Public API

    func refresh() {
        guard let auth = loadAuth() else {
            DispatchQueue.main.async {
                self.isAuthenticated = false
                self.errorMessage = "Codex auth missing. Run `codex` to sign in."
                self.quotas = []
            }
            return
        }
        guard let tokens = auth.tokens, !tokens.access_token.isEmpty else {
            DispatchQueue.main.async {
                self.isAuthenticated = false
                self.errorMessage = "Codex auth has no access_token. Re-run `codex` to refresh."
                self.quotas = []
            }
            return
        }

        DispatchQueue.main.async {
            self.isAuthenticated = true
            self.isLoading = true
            self.errorMessage = nil
        }

        var request = URLRequest(url: Self.chatgptUsageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(tokens.access_token)", forHTTPHeaderField: "Authorization")
        if let accountId = tokens.account_id, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                self.lastRefresh = Date()

                if let error = error {
                    self.errorMessage = "Codex usage fetch failed: \(error.localizedDescription)"
                    return
                }
                guard let http = response as? HTTPURLResponse, let data = data else {
                    self.errorMessage = "Codex usage: no response"
                    return
                }
                switch http.statusCode {
                case 200:
                    self.applyResponse(data: data)
                case 401, 403:
                    // v1: don't implement OAuth refresh. Tell the user how to recover.
                    self.errorMessage = "Codex auth expired. Run `codex` once to refresh tokens."
                    self.quotas = []
                case 429:
                    self.errorMessage = "Codex API rate-limited; will retry next cycle."
                default:
                    let preview = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
                    self.errorMessage = "Codex usage HTTP \(http.statusCode): \(preview)"
                }
            }
        }.resume()
    }

    // MARK: - Internal

    private func loadAuth() -> CodexAuthFile? {
        let url = URL(fileURLWithPath: Self.authFilePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CodexAuthFile.self, from: data)
    }

    private func applyResponse(data: Data) {
        guard let response = CodexUsageResponse.decode(data) else {
            errorMessage = "Codex usage: unrecognized response shape."
            return
        }
        let snapshots = response.snapshots
        // Codex CLI prefers the snapshot with limit_id == "codex"; fall back to first.
        let snapshot = snapshots.first(where: { $0.limit_id == "codex" }) ?? snapshots.first
        guard let s = snapshot else {
            errorMessage = "Codex usage: no snapshots."
            return
        }

        var built: [UsageQuota] = []
        if let p = s.primary {
            built.append(UsageQuota(
                label: "Session (\(formatWindow(p.window_minutes)))",
                icon: "bolt.fill",
                utilization: p.used_percent,
                resetsAt: p.resets_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ))
        }
        if let sec = s.secondary {
            built.append(UsageQuota(
                label: "Weekly (\(formatWindow(sec.window_minutes)))",
                icon: "calendar",
                utilization: sec.used_percent,
                resetsAt: sec.resets_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ))
        }

        quotas = built
        errorMessage = built.isEmpty ? "Codex usage: snapshot had no windows." : nil
    }

    private func formatWindow(_ minutes: Int?) -> String {
        guard let m = minutes, m > 0 else { return "rolling" }
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 48 { return "\(h)h" }
        return "\(h / 24)d"
    }

    private func scheduleAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Burn-rate projections (mirrors UsageManager pattern)

    /// Find the session-window quota by label match. Lightweight; no caching.
    private var sessionQuota: UsageQuota? {
        quotas.first(where: { $0.label.lowercased().contains("session") })
    }

    private var weeklyQuota: UsageQuota? {
        quotas.first(where: { $0.label.lowercased().contains("weekly") })
    }

    private func projectLimit(
        for quota: UsageQuota?,
        windowDuration: TimeInterval,
        minElapsed: TimeInterval,
        minUtilization: Double
    ) -> UsageManager.LimitProjection {
        guard let q = quota,
              let resetsAt = q.resetsAt,
              q.utilization > minUtilization else { return .insufficientData }

        let timeRemaining = resetsAt.timeIntervalSinceNow
        let timeElapsed = windowDuration - timeRemaining

        guard timeElapsed > minElapsed else { return .insufficientData }

        let ratePerSecond = q.utilization / timeElapsed
        guard ratePerSecond > 0 else { return .insufficientData }

        let remainingPercent = 100 - q.utilization
        let secondsToLimit = remainingPercent / ratePerSecond

        if secondsToLimit > timeRemaining { return .safe }

        let days = Int(secondsToLimit) / (24 * 3600)
        let hours = (Int(secondsToLimit) % (24 * 3600)) / 3600
        let minutes = (Int(secondsToLimit) % 3600) / 60

        let label: String
        if days > 0 {
            label = "~\(days)d \(hours)h"
        } else if hours > 0 {
            label = "~\(hours)h \(minutes)m"
        } else {
            label = "~\(minutes)m"
        }
        return .approaching(label: label, secondsToLimit: secondsToLimit)
    }

    var sessionLimitProjection: UsageManager.LimitProjection {
        projectLimit(for: sessionQuota, windowDuration: 5 * 3600, minElapsed: 300, minUtilization: 5)
    }

    var weeklyLimitProjection: UsageManager.LimitProjection {
        projectLimit(for: weeklyQuota, windowDuration: 7 * 24 * 3600, minElapsed: 1800, minUtilization: 2)
    }

    var mostUrgentApproaching: (window: String, label: String, secondsToLimit: TimeInterval)? {
        let candidates: [(String, UsageManager.LimitProjection)] = [
            ("Session", sessionLimitProjection),
            ("Weekly", weeklyLimitProjection)
        ]
        let approaching = candidates.compactMap { name, proj -> (String, String, TimeInterval)? in
            if case .approaching(let label, let secs) = proj { return (name, label, secs) }
            return nil
        }
        return approaching.min(by: { $0.2 < $1.2 }).map {
            (window: $0.0, label: $0.1, secondsToLimit: $0.2)
        }
    }

    var allWindowsSafe: Bool {
        let projections = [sessionLimitProjection, weeklyLimitProjection]
        let anyApproaching = projections.contains {
            if case .approaching = $0 { return true }
            return false
        }
        let anySafe = projections.contains {
            if case .safe = $0 { return true }
            return false
        }
        return !anyApproaching && anySafe
    }

    var burnRateUnavailableReason: String? {
        if case .insufficientData = sessionLimitProjection,
           case .insufficientData = weeklyLimitProjection {
            return "Need a few minutes of active usage in the current window to project a limit."
        }
        return nil
    }
}
