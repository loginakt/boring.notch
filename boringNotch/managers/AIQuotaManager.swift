//
//  AIQuotaManager.swift
//  boringNotch
//

import AppKit
import Combine
import Defaults
import Foundation
import Security

/// Polls Claude usage every 2 minutes, but only while the Claude app is running.
/// Otherwise the last successful result (persisted across launches) is shown and
/// the user can still trigger a one-off refresh by hand.
@MainActor
final class AIQuotaManager: ObservableObject {
    static let shared = AIQuotaManager()

    private static let claudeBundleID = "com.anthropic.claudefordesktop"
    private static let lastResultKey = "aiQuotaLastClaudeResult"

    @Published var claudeQuota: AIQuotaResult?
    @Published var isLoading = false
    @Published private(set) var isClaudeRunning = false
    /// True once Claude rejects the stored sign-in; cleared by the next successful fetch.
    @Published private(set) var signInExpired = false

    private var refreshTask: Task<Void, Never>?
    private var defaultsCancellable: AnyCancellable?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshPolicy = AIQuotaRefreshPolicy()

    private init() {
        claudeQuota = Self.loadLastResult()
        isClaudeRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == Self.claudeBundleID }

        let center = NSWorkspace.shared.notificationCenter
        let claudeBundleID = Self.claudeBundleID
        for (name, running) in [
            (NSWorkspace.didLaunchApplicationNotification, true),
            (NSWorkspace.didTerminateApplicationNotification, false),
        ] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == claudeBundleID else { return }
                Task { @MainActor in AIQuotaManager.shared.claudeRunningChanged(running) }
            })
        }

        defaultsCancellable = Defaults.publisher(.showAIQuota)
            .sink { [weak self] change in
                Task { @MainActor in
                    if change.newValue {
                        self?.startAutoRefresh()
                    } else {
                        self?.stopAutoRefresh()
                        if BoringViewCoordinator.shared.currentView == .quota {
                            BoringViewCoordinator.shared.currentView = .home
                        }
                    }
                }
            }

        startAutoRefresh()
    }

    private func claudeRunningChanged(_ running: Bool) {
        isClaudeRunning = running
        if running {
            startAutoRefresh()
        } else {
            stopAutoRefresh()
        }
    }

    func startAutoRefresh() {
        guard Defaults[.showAIQuota], isClaudeRunning else { return }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchAll()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(120))
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }
                await self.fetchAll()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Opening the quota tab refreshes only while Claude is running.
    func refreshIfClaudeRunning() async {
        guard isClaudeRunning else { return }
        await fetchAll()
    }

    /// One-off refresh from the refresh button; works even when Claude is closed
    /// and retries right away after a sign-in failure (the user may have just signed in).
    func refreshNow() async {
        refreshPolicy.clearAuthFailure(.claude)
        await fetchAll()
    }

    func fetchAll() async {
        guard Defaults[.showAIQuota], !isLoading else { return }

        isLoading = true
        let newClaude = await fetchClaudeQuota()
        if newClaude.success || claudeQuota == nil {
            claudeQuota = newClaude
        }
        if newClaude.success {
            signInExpired = false
            Self.saveLastResult(newClaude)
        } else if newClaude.credentialStatus == .expired, !signInExpired {
            signInExpired = true
            ClaudeBridge.shared.postNotice(
                "Your Claude sign-in expired, so usage can't update. Run claude in Terminal to sign in again.",
                source: "Usage quota",
                duration: 15
            )
        }
        isLoading = false
    }

    private static func loadLastResult() -> AIQuotaResult? {
        guard let data = UserDefaults.standard.data(forKey: lastResultKey) else { return nil }
        return try? JSONDecoder().decode(AIQuotaResult.self, from: data)
    }

    private static func saveLastResult(_ result: AIQuotaResult) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        UserDefaults.standard.set(data, forKey: lastResultKey)
    }

    func fetchClaudeQuota() async -> AIQuotaResult {
        if !refreshPolicy.canRequest(.claude),
           let message = refreshPolicy.blockMessage(for: .claude) {
            print("[AIQuota] Claude: skipping usage fetch, \(message)")
            return .unavailable(
                provider: .claude,
                status: .valid,
                message: message
            )
        }

        // Try XPC helper first (file-based, no password prompt)
        let credentials = await XPCHelperClient.shared.readClaudeCredentials()
        let credentialStatus = CredentialStatus(rawStatus: credentials.status)
        print("[AIQuota] Claude credentials via XPC: status=\(credentials.status), hasToken=\(credentials.accessToken != nil), message=\(credentials.message ?? "nil")")

        if let token = credentials.accessToken, !token.isEmpty {
            return await fetchClaudeUsage(token: token, credentialStatus: credentialStatus)
        }

        // Fall back to Keychain (may trigger macOS password prompt on unsigned builds)
        let keychainToken = Self.readKeychainPasswordFromMainApp(service: "Claude Code-credentials")
        if let keychainToken, !keychainToken.isEmpty {
            print("[AIQuota] Claude: got token from main-app Keychain read")
            if let data = keychainToken.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let oauth = object["claudeAiOauth"] as? [String: Any] ?? object["claude.ai_oauth"] as? [String: Any],
               let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty {
                return await fetchClaudeUsage(token: accessToken, credentialStatus: .valid)
            }
        }

        return .unavailable(
            provider: .claude,
            status: credentialStatus,
            message: credentials.message
        )
    }

    private func fetchClaudeUsage(token: String, credentialStatus: CredentialStatus) async -> AIQuotaResult {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let data = try await data(for: request, provider: .claude)
            let result = try AIQuotaParser.decodeClaudeQuota(from: data)
            refreshPolicy.recordSuccess(.claude)
            return result
        } catch let error as AIQuotaRequestError {
            switch error {
            case .rateLimited(let retryAfter):
                refreshPolicy.recordRateLimit(.claude, retryAfter: retryAfter)
                return .unavailable(
                    provider: .claude,
                    status: credentialStatus,
                    message: refreshPolicy.blockMessage(for: .claude) ?? "Rate limited. Will retry shortly."
                )
            case .expired:
                refreshPolicy.recordAuthFailure(.claude)
                return .unavailable(
                    provider: .claude,
                    status: .expired,
                    message: refreshPolicy.blockMessage(for: .claude) ?? "Token expired. Re-login with CLI."
                )
            case .api:
                return error.result(provider: .claude, fallbackStatus: credentialStatus)
            }
        } catch {
            return .unavailable(
                provider: .claude,
                status: credentialStatus,
                message: "Failed to parse Claude usage: \(error.localizedDescription)"
            )
        }
    }

    private func data(for request: URLRequest, provider: AIProvider) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIQuotaRequestError.api("Invalid response")
            }
            print("[AIQuota] \(provider.displayName): usage HTTP \(httpResponse.statusCode)")

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw AIQuotaRequestError.expired("Authentication failed. Re-login with \(provider.displayName) CLI.")
            }

            if httpResponse.statusCode == 429 {
                let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Int.init)
                throw AIQuotaRequestError.rateLimited(retryAfter: retryAfter)
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw AIQuotaRequestError.api("HTTP \(httpResponse.statusCode): \(body.truncatedForDisplay)")
            }

            return data
        } catch let error as AIQuotaRequestError {
            throw error
        } catch {
            throw AIQuotaRequestError.api("Network error: \(error.localizedDescription)")
        }
    }

    /// Read a Keychain password directly from the main app process.
    /// GUI apps can trigger the macOS Keychain authorization prompt.
    private static func readKeychainPasswordFromMainApp(service: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        print("[AIQuota] Main-app Keychain read for '\(service)': OSStatus \(status)")

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum AIQuotaRequestError: Error {
    case expired(String)
    case api(String)
    case rateLimited(retryAfter: Int?)

    func result(provider: AIProvider, fallbackStatus: CredentialStatus) -> AIQuotaResult {
        switch self {
        case .expired(let message):
            return .unavailable(provider: provider, status: .expired, message: message)
        case .api(let message):
            return .unavailable(provider: provider, status: fallbackStatus, message: message)
        case .rateLimited:
            return .unavailable(provider: provider, status: fallbackStatus, message: "Rate limited. Will retry shortly.")
        }
    }
}

private extension String {
    var truncatedForDisplay: String {
        guard count > 180 else { return self }
        return String(prefix(180)) + "..."
    }
}
