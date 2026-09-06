//
//  AntigravityState.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-09-06.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import Foundation

/// Antigravity 相关的、跨 `Account` / `UserSettings` 共用的派生状态，
/// 独立于 `UserSettings` 本体存放，避免其继续膨胀。

extension Account {
    /// 一个 Antigravity 账户的凭据来源，从 `sessionKey` 是否为空派生，不是新增的存储字段。
    /// - Important: 与 `UserSettings.isCLIDerivedCodexAccount` 同一判定思路 ——
    ///   `.keychain` 来源的账户恒为空 `sessionKey`（凭据现读现用，绝不落盘）；
    ///   `.oauth` 来源的账户把 refresh token 存在这里。
    /// - Important: 非 Antigravity 账户返回 nil（不像
    ///   `isCLIDerivedCodexAccount` 那样把 provider 判定编码进谓词本身，这里用 Optional
    ///   代替，调用方仍需自行按 `provider` 过滤，但至少不会对 Claude/Codex 账户返回一个
    ///   看似有意义的值）。
    var antigravitySource: AntigravitySource? {
        guard provider == .antigravity else { return nil }
        return sessionKey.isEmpty ? .keychain : .oauth
    }
}

/// 覆盖 Antigravity 两个凭据来源的失败：既包括 `AntigravityAuthError`（凭据/登录层面），
/// 也包括 `AntigravityAPIService.performFetch` 可能产出的 `UsageError`（网络/解码/HTTP 状态）。
/// - Important: 不是 `AntigravityAuthError` 的改名 typealias —— `mergeAntigravityResult`
///   实际收到的错误横跨两种类型，之前的 typealias 会在编译期悄悄丢弃 `UsageError` 分支的信息。
///   结构对照 `CodexSourceError`（`CodexAPIService.swift`）：
///   `errorDescription` 是弹出框用的单行短文案，`authTabDescription` 是设置页用的完整文案。
/// - Important: 本地化文案（`L.Error.antigravity_*`）覆盖全部 6 个 locale；
///   这里的两套 switch 只做「case → 具体 key」的映射，不持有任何文案原文。
struct AntigravitySourceError: LocalizedError {
    /// 出错时实际在用的来源；决定同一个 `UsageError` 该按哪套措辞解释
    let source: AntigravitySource
    let underlying: Error

    /// `AntigravityAuthError` case → 弹出框单行文案。所有 `L.Error.antigravity_*` 映射都集中在
    /// 这一处（而不是 `AntigravityAuthError` 自己的某个 computed property）——`AntigravityAuthError`
    /// 是 `nonisolated`（三个 `nonisolated … @unchecked Sendable` 服务在后台队列构造/抛出它），
    /// 而 `L.*` 在 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 下是 MainActor 隔离的；把映射搬到
    /// 这里、只在明确的 MainActor 调用方（`AuthSettingsView` / `DataRefreshManager`）读取，才不会
    /// 让 `AntigravityAuthError` 悄悄继承一个不受强制检查的默认隔离。
    private func popoverText(for authError: AntigravityAuthError) -> String {
        switch authError {
        case .keychainNotFound:
            return L.Error.antigravityKeychainNotFoundPopover
        // `OSStatus` 是内部诊断值，绝不进用户可见文案——
        // 调用方在记录日志时应自行带上原始状态码，这里只给一句安全的通用文案。
        case .keychainAccessDenied:
            return L.Error.antigravityKeychainAccessDeniedPopover
        case .keychainEntitlementMissing:
            return L.Error.antigravityKeychainEntitlementMissingPopover
        case .keychainMalformed:
            return L.Error.antigravityKeychainMalformedPopover
        case .noAccessToken:
            return L.Error.antigravityNoAccessTokenPopover
        case .keychainNotConnected:
            return L.Error.antigravityKeychainNotConnectedPopover
        case .signInCancelled:
            return L.Error.antigravitySignInCancelledPopover
        case .signInAlreadyInProgress:
            return L.Error.antigravitySignInAlreadyInProgressPopover
        case .loopbackFailed:
            return L.Error.antigravityLoopbackFailedPopover
        case .stateMismatch:
            return L.Error.antigravityStateMismatchPopover
        // Google 的服务端错误原文长度不受我们控制，直接塞进一个固定尺寸的登录窗口既不安全也不
        // 美观——原文只应流向 `Logger`（调用方已在抛出处记录），
        // 这里给用户一句安全的定长文案。
        case .codeExchangeFailed:
            return L.Error.antigravityCodeExchangeFailedPopover
        case .refreshTokenRevoked:
            return L.Error.antigravityRefreshTokenRevokedPopover
        case .secretsUnavailable:
            return L.Error.antigravitySecretsUnavailablePopover
        case .expiredAndUnrefreshable:
            return L.Error.antigravityExpiredUnrefreshablePopover
        case .subscriptionRequired:
            // 不带原始 HTTP 状态码——那是内部诊断信息，绝不能进用户可见文案。
            return L.Error.antigravitySubscriptionRequiredPopover
        }
    }

    /// 弹出框用的单行文案
    var errorDescription: String? {
        if let authError = underlying as? AntigravityAuthError {
            return popoverText(for: authError)
        }
        if let usageError = underlying as? UsageError {
            // 穷举而非 `default:`——第一方枚举新增分支时必须编译失败提醒补全措辞，
            // 而不是静默落到通用文案。
            switch usageError {
            case .unauthorized:
                return L.Error.antigravityUsageUnauthorizedPopover
            case .rateLimited:
                return L.Error.antigravityUsageRateLimitedPopover
            case .invalidURL, .noData, .sessionExpired, .cloudflareBlocked, .noCredentials,
                 .networkError, .decodingError, .httpError:
                return usageError.localizedDescription
            }
        }
        return underlying.localizedDescription
    }

    /// Auth 标签页用的完整文案
    var authTabDescription: String? {
        if let authError = underlying as? AntigravityAuthError {
            // 穷举而非 `default:`——同上。
            switch authError {
            case .keychainNotFound:
                return L.Error.antigravityKeychainNotFoundAuthTab
            case .keychainAccessDenied, .keychainEntitlementMissing:
                return L.Error.antigravityKeychainAccessDeniedAuthTab
            case .keychainMalformed, .noAccessToken:
                return L.Error.antigravityKeychainMalformedAuthTab
            case .keychainNotConnected:
                return L.Error.antigravityKeychainNotConnectedAuthTab
            case .refreshTokenRevoked:
                return L.Error.antigravityRefreshTokenRevokedAuthTab
            case .expiredAndUnrefreshable:
                return L.Error.antigravityExpiredUnrefreshableAuthTab
            case .subscriptionRequired:
                return L.Error.antigravitySubscriptionRequiredAuthTab
            case .signInCancelled, .signInAlreadyInProgress, .loopbackFailed, .stateMismatch,
                 .codeExchangeFailed, .secretsUnavailable:
                return popoverText(for: authError)
            }
        }
        if let usageError = underlying as? UsageError, case .unauthorized = usageError {
            return L.Error.antigravityUsageUnauthorizedAuthTab
        }
        return errorDescription
    }
}

/// 本地客户端 300s 节流跳过——**不是**一次请求失败，与服务端真实返回的 HTTP 429
/// （映射为 `UsageError.rateLimited`）必须是两个不同的类型，否则调用方无法区分
/// 「我们自己没发请求」和「服务端明确拒绝了」，会把持续的服务端限流悄悄吞掉不做任何提示。
enum AntigravityFetchSkipped: Error {
    /// 距上次成功拉取不足 `AntigravityAPIService` 的最小间隔（300s），本次调用未发出网络请求
    case clientThrottled
}
