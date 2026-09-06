//
//  AntigravityAuthError.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-09-06.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import Foundation

/// Antigravity 认证失败的具体原因，覆盖两个凭据来源（Keychain / 应用内 OAuth）。
nonisolated enum AntigravityAuthError: Error {
    // MARK: Source A —— 钥匙串

    /// 钥匙串中没有该条目 —— agy 未安装或未登录
    case keychainNotFound
    /// 用户在 ACL 弹窗中点了「拒绝」，或交互被系统阻止（`errSecInteractionNotAllowed` 等）
    case keychainAccessDenied(OSStatus)
    /// 沙盒缺少读取该条目所需的 entitlement（`errSecMissingEntitlement`）—— 这正是 Source A
    /// spike（步骤 6）要检测的失败模式，绝不能和普通的「用户拒绝授权」混为一谈
    case keychainEntitlementMissing(OSStatus)
    /// 找到了条目但没有 `go-keyring-base64:` 前缀 / base64 解不开 / JSON 解不开
    case keychainMalformed
    /// 解出来了但 access_token 为空
    case noAccessToken
    /// 尚未成功执行过一次用户手势触发的 `AntigravityTokenProvider.connectKeychain(_:)`
    /// （或上一次失败了）——内存里没有可用的 Keychain 凭据，且**绝不**在这里静默去读一次
    /// 钥匙串。
    case keychainNotConnected

    // MARK: Source B —— 应用内登录

    /// 用户主动取消了浏览器登录
    case signInCancelled
    /// 上一轮 `AntigravitySignInCoordinator.start()` 还没交付终态结果，就又发起了一轮新的登录 ——
    /// 拒绝第二轮，避免静默丢弃第一轮的 completion
    case signInAlreadyInProgress
    /// 回环监听器超时（180s）或端口无法绑定（多半是缺 network.server entitlement）
    case loopbackFailed(underlying: Error?)
    /// `state` 不匹配 —— 可能是并发登录或被篡改，一律拒绝
    case stateMismatch
    /// 授权码换 token 失败，携带 Google 返回的 error / error_description 原文
    case codeExchangeFailed(String)
    /// 本地已存的 refresh token 被 Google 拒绝（用户在 Google 账户页撤销了授权）
    case refreshTokenRevoked

    // MARK: 共用

    /// OAuth secrets 资源缺失 —— 整个 Antigravity 能力静默关闭
    case secretsUnavailable
    /// access_token 已过期且无法刷新
    case expiredAndUnrefreshable(since: Date?)
    /// HTTP 403 —— `cloudcode-pa.googleapis.com` 前面没有 Cloudflare，真实原因是订阅未开通
    /// （`SUBSCRIPTION_REQUIRED`）或请求的 scope 被拒绝；绝不能映射成 `cloudflareBlocked`
    case subscriptionRequired
}

// MARK: - User-facing description

// `AntigravityAuthError` is deliberately **not** `LocalizedError` and has no member that reads
// `L.*` (MainActor-isolated under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). The enum itself
// is `nonisolated` (three `nonisolated … @unchecked Sendable` services — `AntigravityCredentialStore`,
// `AntigravityLoopbackServer`, `AntigravityTokenProvider` — construct and throw these cases from
// background queues), so a `LocalizedError` conformance here would either (a) silently inherit an
// unenforced default MainActor isolation on its `errorDescription` witness — a guardrail
// gap this type must not reintroduce — or (b) if pinned `@MainActor` explicitly,
// make the conformance itself "cross into main-actor-isolated code", a warning today and an error
// under the Swift 6 language mode. All `L.Error.antigravity_*` text mapping therefore lives at the
// view-facing layer instead: `AntigravitySourceError` (`AntigravityState.swift`), which is only
// ever constructed and read on the main actor (`AuthSettingsView`, `DataRefreshManager`).
