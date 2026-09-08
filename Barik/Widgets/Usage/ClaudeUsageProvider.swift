import Foundation
import Security

/// Fetches Claude usage / rate-limit windows the same way Claude Code does:
/// it reads the local OAuth access token and calls Anthropic's OAuth usage
/// endpoint. Modeled on stablyai/orca's rate-limit implementation.
struct ClaudeUsageProvider: UsageProvider {
    let id = "claude"
    let displayName = "Claude"

    /// Optional profile config directory (defaults to `~/.claude`). Supplying a
    /// different directory lets multiple Claude profiles be tracked side by side.
    var configDirectory: URL

    init(configDirectory: URL? = nil) {
        self.configDirectory =
            configDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude")
    }

    private static let usageURL = URL(
        string: "https://api.anthropic.com/api/oauth/usage")!

    func fetchUsage() async -> ProviderUsageSnapshot {
        let account = readAccountEmail()

        guard let token = readAccessToken() else {
            return snapshot(
                account: account, windows: [], status: .notSignedIn)
        }

        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(
            "claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(
                for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                return snapshot(
                    account: account, windows: [], status: .notSignedIn)
            }
            guard (200..<300).contains(code) else {
                return snapshot(
                    account: account, windows: [],
                    status: .error("HTTP \(code)"))
            }
            let decoded = try JSONDecoder().decode(
                UsageResponse.self, from: data)
            return snapshot(
                account: account, windows: decoded.windows(), status: .ok)
        } catch {
            return snapshot(
                account: account, windows: [],
                status: .error(error.localizedDescription))
        }
    }

    private func snapshot(
        account: String?, windows: [UsageWindow], status: UsageStatus
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerId: id, displayName: displayName, account: account,
            windows: windows.sorted { $0.usedPercent > $1.usedPercent },
            status: status,
            updatedAt: status == .ok ? Date() : nil)
    }

    // MARK: - Credentials

    /// Reads the OAuth access token, preferring the credentials file (no
    /// Keychain prompt) and falling back to the Keychain item Claude Code writes.
    private func readAccessToken() -> String? {
        if let token = tokenFromCredentialsFile() { return token }
        return tokenFromKeychain()
    }

    private func tokenFromCredentialsFile() -> String? {
        let url = configDirectory.appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.parseToken(from: data)
    }

    private func tokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return Self.parseToken(from: data)
    }

    private static func parseToken(from data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else { return nil }
        return token
    }

    /// Best-effort account label from `~/.claude.json` (`oauthAccount.emailAddress`).
    private func readAccountEmail() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let oauth = root["oauthAccount"] as? [String: Any]
        else { return nil }
        return oauth["emailAddress"] as? String
    }
}

// MARK: - Response decoding

/// Mirrors the `GET /api/oauth/usage` payload. `limits[]` is the primary,
/// general source (session / weekly_all / weekly_scoped-with-model); the
/// top-level windows are used as a fallback for older responses.
private struct UsageResponse: Decodable {
    let limits: [LimitEntry]?
    let five_hour: Window?
    let seven_day: Window?

    struct Window: Decodable {
        let utilization: Double?
        let used_percentage: Double?
        let resets_at: APIDate?
        var percent: Double? { utilization ?? used_percentage }
    }

    struct LimitEntry: Decodable {
        let kind: String?
        let percent: Double?
        let resets_at: APIDate?
        let scope: Scope?

        struct Scope: Decodable {
            let model: Model?
            struct Model: Decodable { let display_name: String? }
        }
    }

    func windows() -> [UsageWindow] {
        if let limits, !limits.isEmpty {
            return limits.compactMap { entry in
                guard let percent = entry.percent else { return nil }
                let modelName = entry.scope?.model?.display_name
                return UsageWindow(
                    id: Self.windowID(kind: entry.kind, model: modelName),
                    title: Self.title(kind: entry.kind, model: modelName),
                    usedPercent: percent,
                    resetsAt: entry.resets_at?.date)
            }
        }

        var fallback: [UsageWindow] = []
        if let five = five_hour, let percent = five.percent {
            fallback.append(
                UsageWindow(
                    id: "session", title: "5-hour", usedPercent: percent,
                    resetsAt: five.resets_at?.date))
        }
        if let week = seven_day, let percent = week.percent {
            fallback.append(
                UsageWindow(
                    id: "weekly_all", title: "Weekly", usedPercent: percent,
                    resetsAt: week.resets_at?.date))
        }
        return fallback
    }

    private static func windowID(kind: String?, model: String?) -> String {
        let base = kind ?? "unknown"
        if let model, !model.isEmpty { return "\(base):\(model)" }
        return base
    }

    private static func title(kind: String?, model: String?) -> String {
        switch kind {
        case "session":
            return "5-hour"
        case "weekly_all":
            return "Weekly"
        case "weekly_scoped":
            if let model, !model.isEmpty { return "Weekly · \(model)" }
            return "Weekly (scoped)"
        default:
            let name = (kind ?? "Limit")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            if let model, !model.isEmpty { return "\(name) · \(model)" }
            return name
        }
    }
}

/// Decodes `resets_at`, which may be an ISO-8601 string or a numeric epoch
/// (seconds or milliseconds).
private struct APIDate: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            date = APIDate.parse(string)
        } else if let number = try? container.decode(Double.self) {
            let seconds = number > 10_000_000_000 ? number / 1000 : number
            date = Date(timeIntervalSince1970: seconds)
        } else {
            date = nil
        }
    }

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}
