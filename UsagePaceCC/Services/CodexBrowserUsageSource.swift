//
//  CodexBrowserUsageSource.swift
//  UsagePaceCC
//
//  Created by f-is-h on 2026-04-24.
//  Copyright © 2025 f-is-h. All rights reserved.
//

import Foundation
import OSLog

/// Codex 浏览器 Cookie 来源，两步认证流程：
///   1. GET /api/auth/session（用 session-token Cookie）→ 获取 accessToken
///   2. GET /backend-api/wham/usage（用 Bearer token）→ 获取用量数据
/// - Note: 从原 `CodexAPIService` 原样移动而来（phase-03 Step 5），仅改动了封闭类型名、
///   访问级别，以及把 `session: URLSession` 从实例属性变为参数（协议要求）。逻辑本身未改动。
final class CodexBrowserUsageSource: CodexUsageSource {

    private let baseURL = "https://chatgpt.com"
    private let settings = UserSettings.shared

    /// 当前进行中的任务
    private var activeTasks: [URLSessionDataTask] = []

    var source: CodexSource { .browser }

    var isConfigured: Bool { settings.isBrowserSourceConfigured }

    // MARK: - Public

    /// 获取 Codex 用量（两步：session → usage）
    func fetchUsage(session: URLSession, completion: @escaping (Result<CodexUsageData, Error>) -> Void) {
        let sessionToken = settings.codexSessionToken

        fetchAccessToken(session: session, sessionToken: sessionToken) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .failure(let error):
                completion(.failure(error))

            case .success(let accessToken):
                self.fetchWhamUsage(session: session, accessToken: accessToken, completion: completion)
            }
        }
    }

    func cancel() {
        activeTasks.forEach { $0.cancel() }
        activeTasks.removeAll()
        Logger.api.debug("Codex Browser: 已取消所有网络请求")
    }

    // MARK: - Private: Step 1 — Session → accessToken

    /// 第一步：用 session-token Cookie 换取 accessToken
    private func fetchAccessToken(session: URLSession, sessionToken: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/api/auth/session") else {
            completion(.failure(UsageError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.assumesHTTP3Capable = false
        CodexAPIHeaderBuilder.applySessionHeaders(to: &request, sessionToken: sessionToken)

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                Logger.api.debug("Codex session error: \(error.localizedDescription)")
                completion(.failure(UsageError.networkError))
                return
            }

            guard let data = data else {
                completion(.failure(UsageError.noData))
                return
            }

            if let jsonString = String(data: data, encoding: .utf8) {
                Logger.api.debug("Codex session response received: \(data.count) bytes")
                if jsonString.contains("<!DOCTYPE html>") || jsonString.contains("<html") {
                    completion(.failure(UsageError.cloudflareBlocked))
                    return
                }
            }

            if let httpResponse = response as? HTTPURLResponse {
                Logger.api.debug("Codex session HTTP status: \(httpResponse.statusCode)")
                switch httpResponse.statusCode {
                case 200...299: break
                case 401: completion(.failure(UsageError.unauthorized)); return
                case 403: completion(.failure(UsageError.cloudflareBlocked)); return
                case 429: completion(.failure(UsageError.rateLimited)); return
                default:
                    completion(.failure(UsageError.httpError(statusCode: httpResponse.statusCode)))
                    return
                }
            }

            let decoder = JSONDecoder()
            do {
                let sessionResponse = try decoder.decode(CodexSessionResponse.self, from: data)
                guard let accessToken = sessionResponse.accessToken, !accessToken.isEmpty else {
                    Logger.api.error("Codex session response missing accessToken")
                    completion(.failure(UsageError.sessionExpired))
                    return
                }
                completion(.success(accessToken))
            } catch {
                Logger.api.debug("Codex session decode error: \(error.localizedDescription)")
                completion(.failure(UsageError.decodingError))
            }
        }

        activeTasks.append(task)
        task.resume()
    }

    // MARK: - Private: Step 2 — accessToken → usage

    /// 第二步：用 Bearer accessToken 查询用量
    private func fetchWhamUsage(session: URLSession, accessToken: String, completion: @escaping (Result<CodexUsageData, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/backend-api/wham/usage") else {
            completion(.failure(UsageError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.assumesHTTP3Capable = false
        CodexAPIHeaderBuilder.applyUsageHeaders(to: &request, accessToken: accessToken)

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                Logger.api.debug("Codex usage error: \(error.localizedDescription)")
                completion(.failure(UsageError.networkError))
                return
            }

            guard let data = data else {
                completion(.failure(UsageError.noData))
                return
            }

            if let jsonString = String(data: data, encoding: .utf8) {
                Logger.api.debug("Codex usage response received: \(data.count) bytes")
                if jsonString.contains("<!DOCTYPE html>") || jsonString.contains("<html") {
                    completion(.failure(UsageError.cloudflareBlocked))
                    return
                }
            }

            if let httpResponse = response as? HTTPURLResponse {
                Logger.api.debug("Codex usage HTTP status: \(httpResponse.statusCode)")
                switch httpResponse.statusCode {
                case 200...299: break
                case 401: completion(.failure(UsageError.unauthorized)); return
                case 403: completion(.failure(UsageError.cloudflareBlocked)); return
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
                Logger.api.debug("Codex usage decode error: \(error.localizedDescription)")
                completion(.failure(UsageError.decodingError))
            }
        }

        activeTasks.append(task)
        task.resume()
    }
}
