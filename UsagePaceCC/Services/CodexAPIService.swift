//
//  CodexAPIService.swift
//  UsagePaceCC
//
//  Created by f-is-h on 2026-04-24.
//  Copyright © 2025 f-is-h. All rights reserved.
//

import Foundation
import OSLog

/// Codex API 服务类：路由到两个 `CodexUsageSource` 实现之一（CLI / Browser），
/// 并保留 `validateSessionToken`（WebLogin 流程使用）。
///
/// 用量请求本身（凭据获取 + endpoint + 解码）都在各自的 `CodexUsageSource` 实现里；
/// 这里只做「选哪个来源」和「取消所有请求」。
class CodexAPIService {

    // MARK: - Properties

    private let baseURL = "https://chatgpt.com"
    private let settings = UserSettings.shared
    private let session: URLSession

    /// 恰好两个来源，字面量构建，不做注册表、不做动态扩展（见 plan.md「Dual-Source Arbitration」）
    private let sources: [CodexSource: CodexUsageSource]

    /// 当前进行中的任务（仅 `validateSessionToken` 使用；两个来源各自维护自己的任务列表）
    private var activeTasks: [URLSessionDataTask] = []

    // MARK: - Initialization

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
        self.sources = [
            .cli: CodexCLIUsageSource(),
            .browser: CodexBrowserUsageSource()
        ]
    }

    // MARK: - Public Methods

    /// 获取 Codex 用量：路由到 `settings.effectiveCodexSource` 对应的来源。
    /// - Important: 从不自动切换来源（D9）。失败时的错误会带上来源名称（`CodexSourceError`），
    ///   同一周期内不会去尝试另一个来源——两个来源可能属于不同的 ChatGPT 账户。
    func fetchUsage(completion: @escaping (Result<CodexUsageData, Error>) -> Void) {
        #if DEBUG
        if settings.debugModeEnabled {
            let mockData = createMockData()
            DispatchQueue.main.async { completion(.success(mockData)) }
            return
        }
        #endif

        cancelAllRequests()

        guard let effectiveSource = settings.effectiveCodexSource,
              let usageSource = sources[effectiveSource] else {
            DispatchQueue.main.async { completion(.failure(UsageError.noCredentials)) }
            return
        }

        Logger.api.debug("Codex: 使用来源 \(effectiveSource.rawValue, privacy: .public)")

        usageSource.fetchUsage(session: session) { result in
            DispatchQueue.main.async {
                completion(result.mapError { CodexSourceError(source: effectiveSource, underlying: $0) })
            }
        }
    }

    // MARK: - Validation (used by WebLoginCoordinator)

    /// 验证 session token 并返回账户信息（用于 WebLogin 流程）
    /// - Parameters:
    ///   - sessionToken: __Secure-next-auth.session-token 值
    ///   - completion: 成功返回 (email, displayName)，失败返回 Error
    func validateSessionToken(_ sessionToken: String, completion: @escaping (Result<(email: String, displayName: String), Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/api/auth/session") else {
            completion(.failure(UsageError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.assumesHTTP3Capable = false
        CodexAPIHeaderBuilder.applySessionHeaders(to: &request, sessionToken: sessionToken)

        let task = session.dataTask(with: request) { data, response, error in
            if error != nil {
                DispatchQueue.main.async { completion(.failure(UsageError.networkError)) }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async { completion(.failure(UsageError.noData)) }
                return
            }

            if let jsonString = String(data: data, encoding: .utf8) {
                Logger.api.debug("Codex validate session response received: \(data.count) bytes")
                if jsonString.contains("<!DOCTYPE html>") || jsonString.contains("<html") {
                    DispatchQueue.main.async { completion(.failure(UsageError.cloudflareBlocked)) }
                    return
                }
            }

            if let httpResponse = response as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 200...299: break
                case 401:
                    DispatchQueue.main.async { completion(.failure(UsageError.unauthorized)) }
                    return
                case 403:
                    DispatchQueue.main.async { completion(.failure(UsageError.cloudflareBlocked)) }
                    return
                default:
                    DispatchQueue.main.async {
                        completion(.failure(UsageError.httpError(statusCode: httpResponse.statusCode)))
                    }
                    return
                }
            }

            let decoder = JSONDecoder()
            do {
                let sessionResponse = try decoder.decode(CodexSessionResponse.self, from: data)
                guard let accessToken = sessionResponse.accessToken, !accessToken.isEmpty else {
                    DispatchQueue.main.async { completion(.failure(UsageError.sessionExpired)) }
                    return
                }
                let email = sessionResponse.user?.email ?? ""
                let name = sessionResponse.user?.name ?? email
                let displayName = name.isEmpty ? "Codex" : name
                DispatchQueue.main.async { completion(.success((email: email, displayName: displayName))) }
            } catch {
                DispatchQueue.main.async { completion(.failure(UsageError.decodingError)) }
            }
        }

        activeTasks.append(task)
        task.resume()
    }

    // MARK: - Debug Mock Data

    #if DEBUG
    private func createMockData() -> CodexUsageData {
        let primaryResetAt = Date().addingTimeInterval(3600 * 2.5)
        let secondaryResetAt = Date().addingTimeInterval(3600 * 24 * 3.2)
        let extraPercentage = Double(settings.debugCodexExtraUsagePercentage)
        let debugCreditLimit = Decimal(1000)
        let remainingRatio = max(0, (100 - extraPercentage) / 100.0)
        let balance = debugCreditLimit * Decimal(remainingRatio)
        let balanceValue = balance.doubleValue

        return CodexUsageData(
            primary: .init(percentage: Double(settings.debugCodexPrimaryPercentage), resetsAt: primaryResetAt, windowSeconds: 5 * 3600),
            secondary: .init(percentage: Double(settings.debugCodexSecondaryPercentage), resetsAt: secondaryResetAt, windowSeconds: 7 * 24 * 3600),
            extraUsage: CodexExtraUsageData(
                hasCredits: true,
                unlimited: false,
                overageLimitReached: extraPercentage >= 100,
                spendControlReached: false,
                balance: balance,
                approxLocalMessages: [Int(balanceValue / 14), Int(balanceValue / 2)],
                approxCloudMessages: [Int(balanceValue / 34), Int(balanceValue / 25)],
                visualPercentage: extraPercentage
            )
        )
    }
    #endif
}

private extension Decimal {
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}

// MARK: - UsageProvider

extension CodexAPIService: UsageProvider {
    var providerType: ProviderType { .codex }

    func cancelAllRequests() {
        activeTasks.forEach { $0.cancel() }
        activeTasks.removeAll()
        sources.values.forEach { $0.cancel() }
        Logger.api.debug("Codex: 已取消所有网络请求")
    }
}

// MARK: - CodexSourceError

/// 包装某个 Codex 来源的失败，让错误信息带上是哪个来源出的问题。
/// - Important: 从不自动切换来源（D9/D13）——错误信息只负责让用户看清楚该切哪个，
///   本身不做任何切换动作。措辞按 phase-03 的验证表逐字实现，不在实现期改写。
struct CodexSourceError: LocalizedError {
    let source: CodexSource
    let underlying: Error

    /// 弹出框用的单行文案
    var errorDescription: String? {
        if let cliError = underlying as? CodexCLIAuthError {
            return Self.cliPopoverMessage(for: cliError)
        }
        if let usageError = underlying as? UsageError {
            switch (source, usageError) {
            case (.cli, .unauthorized):
                return L.Error.codexCLIInvalidPopover
            case (.browser, .unauthorized), (.browser, .sessionExpired):
                return L.Error.codexBrowserExpiredPopover
            default:
                break
            }
        }
        return underlying.localizedDescription
    }

    /// Auth 标签页用的完整文案（P07 消费）；此处先按验证表把措辞定死，避免实现期被改写
    var authTabDescription: String? {
        if let cliError = underlying as? CodexCLIAuthError, case .tokenExpired = cliError {
            return L.Error.codexCLIExpiredAuthTab
        }
        if let usageError = underlying as? UsageError {
            switch (source, usageError) {
            case (.cli, .unauthorized):
                return L.Error.codexCLIInvalidAuthTab
            case (.browser, .unauthorized), (.browser, .sessionExpired):
                return L.Error.codexBrowserExpiredAuthTab
            default:
                break
            }
        }
        return errorDescription
    }

    private static func cliPopoverMessage(for error: CodexCLIAuthError) -> String {
        if case .tokenExpired = error {
            return L.Error.codexCLIExpiredPopover
        }
        // 未知/非过期的本地凭据错误（未安装、沙盒拒绝、无法解析等）：不在验证表范围内，
        // 沿用 CodexCLIAuthError 自身的 LocalizedError 文案。
        return error.localizedDescription
    }
}
