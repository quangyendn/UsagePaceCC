//
//  AntigravityAPIService.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-09-06.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import Foundation
import OSLog

/// Antigravity 用量拉取服务：token provider → POST → parse。
/// - Important: `UsageProvider` 协议一致性在文件末尾补上。
/// - Important: `nonisolated`——`activeTasks` / `lastFetchAt` 从 `URLSession` 后台完成回调线程
///   （`performFetch` 的 completion handler）读写，`SensitiveDataRedactor.redactText` 也是在那条
///   后台线程调用的（:125）。在这项目 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 默认下，一个
///   普通 `class` 若不显式声明 `nonisolated` 会隐式变成 MainActor-isolated，届时从后台线程直接
///   触碰这些成员就是隔离违规；今天只是因为 `SWIFT_STRICT_CONCURRENCY = minimal` 才不报错。与
///   `AntigravityTokenProvider` / `AntigravityLoopbackServer` 保持同样的隔离策略，
///   线程安全仍由 `stateLock`（`NSLock`）保证。
/// `@unchecked Sendable`: `activeTasks` / `lastFetchAt` 是唯一的可变存储，均由 `stateLock`
/// （`NSLock`）保护；`session` / `tokenProvider` / `quotaURL` 都是 `let` 且各自 Sendable
/// （`URLSession`、`AntigravityTokenProvider`）。这是手动验证过的不变量，而非编译器能推导的，
/// 因此用 `@unchecked` 而非 plain `Sendable`（否则 `URLSessionDataTask` 的 `@Sendable` completion
/// closure 里捕获 `self` 会被编译器当成非 Sendable 类型报警）。
nonisolated final class AntigravityAPIService: @unchecked Sendable {

    // MARK: - Properties

    private let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    // 禁止使用 v1internal:retrieveUserQuota（单数）—— 消费级账号返回 403 SUBSCRIPTION_REQUIRED

    /// 配额接口要求的 User-Agent。服务端只检查是否含 "Antigravity"，不检查版本号，
    /// 但保留一个版本段以贴近 `agy` 自身的格式（`antigravity-cli/<version>`）。
    /// - Important: 改动这个值前先确认 `retrieveUserQuotaSummary` 仍返回 200——
    ///   判定失败时的报错是 403 "valid license"，会把人引向完全错误的方向。
    private static let userAgent = "antigravity-cli/1.1.27"

    /// 最小拉取间隔 300s，**按账户各自计时**；`force == true`（用户手动刷新）时绕过
    private static let minimumFetchInterval: TimeInterval = 300

    private let session: URLSession
    let tokenProvider: AntigravityTokenProvider

    /// 每账户上次成功拉取时间。键用非 Optional 的 `AntigravityTokenKey`，不用 `UUID?` —— 否则
    /// `.oauth` 且 `accountId == nil` 的调用会退化成与 `.keychain` 相同的 `nil` 键，和 keychain
    /// 账户共享同一份节流计时（与 `AntigravityTokenProvider` 同一个坑）。
    private var lastFetchAt: [AntigravityTokenKey: Date] = [:]
    private let stateLock = NSLock()

    /// 进行中的任务，供 `cancelAllRequests()` 统一取消；每个任务结束时会从这里移除，
    /// 否则会随进程生命周期无限增长。
    private var activeTasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    // MARK: - Initialization

    init(tokenProvider: AntigravityTokenProvider = AntigravityTokenProvider()) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        // 这是纯 bearer-token API，没有 cookie 语义；`ClaudeAPIService` 的 cookie 配置在这里是
        // 复制粘贴的残留，删除。
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
        self.tokenProvider = tokenProvider
    }

    // MARK: - Public Methods

    /// 拉取 Antigravity 用量。
    /// - Parameters:
    ///   - source: 凭据来源
    ///   - accountId: `.oauth` 时必填；`.keychain` 时忽略
    ///   - force: 用户手动刷新时为 true，绕过 300s 节流
    /// - Note: 所有终态回调都在主线程交付——节流拒绝、`accountId` 缺失、token provider 失败、
    ///   网络结果——保持统一约定，方便调用方不必自己判断当前队列。
    /// - Important: `.keychain` 来源绝不在这里触发任何钥匙串读取——`tokenProvider.accessToken`
    ///   只消费 `AntigravityTokenProvider.connectKeychain(_:)` 此前写入内存的凭据；没有凭据时
    ///   直接以 `.keychainNotConnected` 失败。
    func fetchUsage(
        source: AntigravitySource,
        accountId: UUID?,
        force: Bool,
        completion: @escaping (Result<AntigravityUsageData, Error>) -> Void
    ) {
        let throttleKey: AntigravityTokenKey
        switch source {
        case .keychain:
            throttleKey = .keychain
        case .oauth:
            guard let accountId = accountId else {
                DispatchQueue.main.async { completion(.failure(AntigravityAuthError.noAccessToken)) }
                return
            }
            throttleKey = .oauth(accountId)
        }

        if !force, let lastFetch = lastFetch(for: throttleKey), Date().timeIntervalSince(lastFetch) < Self.minimumFetchInterval {
            Logger.api.debug("Antigravity: 300s 节流内跳过请求")
            // 本地节流跳过用专门的 `AntigravityFetchSkipped`，绝不能和服务端真实 429
            // （下面 `case 429` 分支的 `UsageError.rateLimited`）混用同一个 case——否则调用方
            // 无法区分二者，会把持续的服务端限流也当成节流静默吞掉。
            DispatchQueue.main.async { completion(.failure(AntigravityFetchSkipped.clientThrottled)) }
            return
        }

        tokenProvider.accessToken(source: source, accountId: accountId) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let accessToken):
                self.performFetch(accessToken: accessToken, throttleKey: throttleKey, completion: completion)
            }
        }
    }

    func cancelAllRequests() {
        stateLock.lock()
        let tasks = Array(activeTasks.values)
        activeTasks.removeAll()
        stateLock.unlock()
        tasks.forEach { $0.cancel() }
        Logger.api.debug("Antigravity: 已取消所有网络请求")
    }

    // MARK: - Private — Network

    private func performFetch(
        accessToken: String,
        throttleKey: AntigravityTokenKey,
        completion: @escaping (Result<AntigravityUsageData, Error>) -> Void
    ) {
        var request = URLRequest(url: quotaURL)
        request.httpMethod = "POST"
        request.assumesHTTP3Capable = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        // 服务端按 User-Agent 判定调用方：UA 里不含 "Antigravity" 时，即使 token 完全有效、
        // scope 完整，`retrieveUserQuotaSummary` 也会返回 403 PERMISSION_DENIED（文案是
        // "You do not have a valid license of this product"，极具误导性——和授权毫无关系）。
        // 实测：`antigravity-cli/1.1.27`、`antigravity-cli`、`Antigravity/1.1.27` 均放行，
        // 版本号不参与判定；`UsagePaceCC/3.0.0`、`curl/8.0` 一律 403。
        // 因此这里必须以 Antigravity 客户端的身份发起请求——与本功能复用 Antigravity
        // OAuth client 的前提一致，详见 docs/ANTIGRAVITY_INTEGRATION.md。
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("{}".utf8)

        var task: URLSessionDataTask!
        task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            defer { self.removeActiveTask(task) }

            if let error = error {
                let redacted = SensitiveDataRedactor.redactText(error.localizedDescription)
                Logger.api.debug("Antigravity: 请求出错 - \(redacted, privacy: .public)")
                DispatchQueue.main.async { completion(.failure(UsageError.networkError)) }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async { completion(.failure(UsageError.noData)) }
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                Logger.api.debug("Antigravity: HTTP 状态 \(httpResponse.statusCode)")
                switch httpResponse.statusCode {
                case 200...299:
                    break
                case 401:
                    DispatchQueue.main.async { completion(.failure(UsageError.unauthorized)) }
                    return
                case 403:
                    // 没有 Cloudflare 挡在 cloudcode-pa.googleapis.com 前面；403 在这里的真实含义是
                    // 订阅未开通（SUBSCRIPTION_REQUIRED）或请求的 scope 被拒绝，映射成专门的错误
                    // 而不是照抄 Codex/Claude 那套 cloudflareBlocked。
                    DispatchQueue.main.async { completion(.failure(AntigravityAuthError.subscriptionRequired)) }
                    return
                case 429:
                    // 服务端真实限流——与上面本地 300s 节流跳过（`AntigravityFetchSkipped`）
                    // 是两回事，必须继续作为一个可见错误上抛，不能被节流跳过的判断误吞。
                    DispatchQueue.main.async { completion(.failure(UsageError.rateLimited)) }
                    return
                default:
                    DispatchQueue.main.async { completion(.failure(UsageError.httpError(statusCode: httpResponse.statusCode))) }
                    return
                }
            }

            do {
                let response = try JSONDecoder().decode(AntigravityUsageResponse.self, from: data)
                let usageData = AntigravityUsageData.from(response)
                self.markFetchSucceeded(for: throttleKey)
                DispatchQueue.main.async { completion(.success(usageData)) }
            } catch {
                Logger.api.error("Antigravity: 解码失败 - \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { completion(.failure(UsageError.decodingError)) }
            }
        }

        stateLock.lock()
        activeTasks[ObjectIdentifier(task)] = task
        stateLock.unlock()
        task.resume()
    }

    private func removeActiveTask(_ task: URLSessionDataTask) {
        stateLock.lock()
        activeTasks.removeValue(forKey: ObjectIdentifier(task))
        stateLock.unlock()
    }

    // MARK: - Private — Throttle state

    private func lastFetch(for key: AntigravityTokenKey) -> Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastFetchAt[key]
    }

    private func markFetchSucceeded(for key: AntigravityTokenKey) {
        stateLock.lock()
        lastFetchAt[key] = Date()
        stateLock.unlock()
    }

}

// MARK: - UsageProvider

extension AntigravityAPIService: UsageProvider {
    var providerType: ProviderType { .antigravity }
}
