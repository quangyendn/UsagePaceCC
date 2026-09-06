//
//  ProviderType.swift
//  UsagePaceCC
//
//  Created by f-is-h on 2026-04-27.
//  Copyright © 2025 f-is-h. All rights reserved.
//

import Foundation

enum ProviderType: String, Codable, CaseIterable, Hashable {
    case claude
    case codex
    /// Google Antigravity（agy CLI / Antigravity IDE）。
    /// 两个凭据来源，见 `AntigravitySource`：
    /// - `.keychain`：读 agy 写入的登录钥匙串条目，零配置，但恒定单账户；
    /// - `.oauth`：本 App 内 Google 登录，支持多账户。
    case antigravity

    var displayName: String {
        switch self {
        case .claude:      return "Claude"
        case .codex:       return "Codex"
        case .antigravity: return "Antigravity"
        }
    }
}
