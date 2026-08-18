//
//  CodexSource.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-08-17.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import Foundation

/// Codex 凭据来源
/// CLI 从 `~/.codex/auth.json` 读取；Browser 使用 WKWebView 登录后保存的浏览器 Cookie
enum CodexSource: String, Codable, CaseIterable {
    case cli
    case browser

    /// 另一个来源（用于可用性回退判断，见 plan.md Dual-Source Arbitration）
    var other: CodexSource {
        switch self {
        case .cli: return .browser
        case .browser: return .cli
        }
    }
}
