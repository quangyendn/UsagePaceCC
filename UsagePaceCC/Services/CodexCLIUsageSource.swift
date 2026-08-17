//
//  CodexCLIUsageSource.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-08-17.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import Foundation
import OSLog

/// Codex CLI 凭据来源：读取 `~/.codex/auth.json` → GET /backend-api/wham/usage（Bearer）。
///
/// 与 Browser 来源打的是**同一个** endpoint（P01 spike 确认），差异只在凭据获取和第一跳：
/// 这里跳过 `/api/auth/session` 那一步，直接用 CLI 自己的 access_token 作为 Bearer。
/// 响应体沿用与 Browser 相同的 `CodexUsageResponse` 解码器——wire shape 相同，一个解码器足够。
/// - Important: D10（只读，绝不 refresh）。`exp` 校验发生在 `CodexCLIAuthReader.read()` 内部，
///   过期时（`.tokenExpired`）在此直接返回，本次周期内**不会**发出任何网络请求（D13：不回退到 Browser）。
final class CodexCLIUsageSource: CodexUsageSource {

    private let baseURL = "https://chatgpt.com"

    /// 当前进行中的任务
    private var activeTasks: [URLSessionDataTask] = []

    var source: CodexSource { .cli }

    var isConfigured: Bool { UserSettings.shared.isCLISourceConfigured }

    func fetchUsage(session: URLSession, completion: @escaping (Result<CodexUsageData, Error>) -> Void) {
        let auth: CodexCLIAuth
        do {
            auth = try CodexCLIAuthReader.read()
        } catch {
            // .tokenExpired（以及 notInstalled / sandboxDenied / malformed / noAccessToken）全部在这里
            // 短路返回：CodexCLIAuthReader.read() 从不在这些情形下发起任何网络请求（D10/D13）。
            Logger.api.debug("Codex CLI: 凭据本地校验失败，跳过网络请求")
            completion(.failure(error))
            return
        }

        guard let url = URL(string: "\(baseURL)/backend-api/wham/usage") else {
            completion(.failure(UsageError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.assumesHTTP3Capable = false
        // P01 spike: Authorization 是唯一 load-bearing header；ChatGPT-Account-Id / User-Agent
        // 不是必需的，但为了与 CLI 自身行为保真而附带（省略 ChatGPT-Account-Id 只会让响应里的
        // account_id 字段为空，不影响 rate-limit 数值）。不发送 X-OpenAI-Fedramp（仅 FedRAMP 账户需要）。
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if !auth.accountId.isEmpty {
            request.setValue(auth.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        Logger.api.debug("Codex CLI: 发起用量请求")

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                Logger.api.debug("Codex CLI usage error: \(error.localizedDescription)")
                completion(.failure(UsageError.networkError))
                return
            }

            guard let data = data else {
                completion(.failure(UsageError.noData))
                return
            }

            if let jsonString = String(data: data, encoding: .utf8) {
                Logger.api.debug("Codex CLI usage response received: \(data.count) bytes")
                if jsonString.contains("<!DOCTYPE html>") || jsonString.contains("<html") {
                    completion(.failure(UsageError.cloudflareBlocked))
                    return
                }
            }

            if let httpResponse = response as? HTTPURLResponse {
                Logger.api.debug("Codex CLI usage HTTP status: \(httpResponse.statusCode)")
                switch httpResponse.statusCode {
                case 200...299: break
                // 401 尽管本地 exp 校验通过（未过期）——token 被撤销/无效。与「已过期」是不同的用户提示。
                case 401: completion(.failure(UsageError.unauthorized)); return
                case 429: completion(.failure(UsageError.rateLimited)); return
                default:
                    completion(.failure(UsageError.httpError(statusCode: httpResponse.statusCode)))
                    return
                }
            }

            let decoder = JSONDecoder()
            do {
                let usageResponse = try decoder.decode(CodexUsageResponse.self, from: data)
                let usageData = usageResponse.toCodexUsageData()
                completion(.success(usageData))
            } catch {
                Logger.api.debug("Codex CLI usage decode error: \(error.localizedDescription)")
                completion(.failure(UsageError.decodingError))
            }
        }

        activeTasks.append(task)
        task.resume()
    }

    func cancel() {
        activeTasks.forEach { $0.cancel() }
        activeTasks.removeAll()
        Logger.api.debug("Codex CLI: 已取消所有网络请求")
    }
}

// MARK: - CodexCLIAuthError localized description

extension CodexCLIAuthError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Codex CLI not detected."
        case .sandboxDenied:
            return "Codex CLI credentials could not be read (permission denied)."
        case .malformed:
            return "Codex CLI credentials file could not be parsed."
        case .noAccessToken:
            return "Codex CLI credentials are missing an access token."
        case .tokenExpired:
            // D13/verbatim wording lives in CodexSourceError so it can also serve the
            // Auth-tab full-text variant; this default keeps the type usable standalone.
            return L.Error.codexCLIExpiredPopover
        }
    }
}
