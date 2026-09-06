//
//  AntigravitySource.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-09-06.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import Foundation

/// Antigravity 凭据来源。
/// - `keychain`：读取 `agy` CLI 写入登录钥匙串的凭据（零配置，但受沙盒 / ACL 影响，恒定单账户）。
/// - `oauth`：本 App 内发起的 Google 登录，自己持有 refresh token（不弹 ACL 授权框，支持多账户）。
nonisolated enum AntigravitySource: String, Codable, CaseIterable {
    case keychain
    case oauth

    /// 另一个来源（用于可用性回退判断）
    var other: AntigravitySource {
        switch self {
        case .keychain: return .oauth
        case .oauth:    return .keychain
        }
    }
}

/// Token 缓存 / 节流状态的键。
/// - Important: 不能用 `UUID?` 直接当键 —— `.oauth` 且 `accountId == nil` 时会退化成 `nil`，
///   与 `.keychain` 用的固定键 `nil` 撞在一起，导致跨来源共享同一份 token 缓存 / 节流计时
///   这个非 `Optional` 的枚举让「keychain 恒定单账户」与
///   「oauth 未指定账户 id（编程错误）」在类型层面区分开，后者必须在构造键之前就被拒绝。
nonisolated enum AntigravityTokenKey: Hashable {
    case keychain
    case oauth(UUID)
}
