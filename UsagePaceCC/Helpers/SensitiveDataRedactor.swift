//
//  SensitiveDataRedactor.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2025-12-01.
//  Copyright © 2025 f-is-h. All rights reserved.
//

import Foundation

/// 敏感数据脱敏工具
/// 提供统一的敏感信息脱敏方法，用于日志记录和诊断报告
/// 支持 Organization ID、Session Key 和文本中的敏感信息脱敏
class SensitiveDataRedactor {
    // MARK: - Public Methods

    /// 脱敏 Organization ID
    /// - Parameter id: 原始 Organization ID
    /// - Returns: 脱敏后的字符串
    /// - Note: 对于短于8位的ID，全部替换为星号；否则保留前4位和后4位
    /// - Example: "12345678-1234-1234-1234-123456789012" -> "1234...9012"
    static func redactOrganizationId(_ id: String) -> String {
        guard id.count > 8 else {
            return String(repeating: "*", count: id.count)
        }
        let prefix = id.prefix(4)
        let suffix = id.suffix(4)
        return "\(prefix)...\(suffix)"
    }

    /// 脱敏 Session Key
    /// - Parameter key: 原始 Session Key
    /// - Returns: 脱敏后的字符串
    /// - Note: 对于 sk-ant- 开头的 key，保留前缀并显示长度；其他情况返回 "***"
    /// - Example: "sk-ant-sid...XXXXX" -> "sk-ant-***...*** (128 chars)"
    static func redactSessionKey(_ key: String) -> String {
        guard key.count > 20 else {
            return "***"
        }

        // 保留前缀 "sk-ant-"
        if key.hasPrefix("sk-ant-") {
            return "sk-ant-***...*** (\(key.count) chars)"
        }

        // 其他格式的 key
        return "***...*** (\(key.count) chars)"
    }

    /// 脱敏文本中的敏感信息
    /// 使用正则表达式查找并替换文本中的 Organization ID 和 Session Key
    /// - Parameter text: 包含敏感信息的原始文本
    /// - Returns: 脱敏后的文本
    /// - Note: 用于日志和诊断输出，自动识别并脱敏常见格式
    static func redactText(_ text: String) -> String {
        var sanitized = text

        // 脱敏 Session Key (保留前4位和后4位)
        // 匹配模式: sessionKey=xxx 或 sessionKey: xxx
        let sessionKeyPattern = "sessionKey[=:]\\s*[\"']?([a-zA-Z0-9-]{20,})[\"']?"
        if let regex = try? NSRegularExpression(pattern: sessionKeyPattern, options: .caseInsensitive) {
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: "sessionKey=***REDACTED***"
            )
        }

        // 脱敏 Organization ID (UUID 格式)
        // 匹配模式: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
        let orgIdPattern = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        if let regex = try? NSRegularExpression(pattern: orgIdPattern, options: .caseInsensitive) {
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: "********-****-****-****-************"
            )
        }

        // 脱敏 Cookie 中的 sessionKey
        // 匹配模式: Cookie: sessionKey=xxx
        let cookiePattern = "Cookie:\\s*sessionKey=([a-zA-Z0-9-]{20,})"
        if let regex = try? NSRegularExpression(pattern: cookiePattern, options: .caseInsensitive) {
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: "Cookie: sessionKey=***REDACTED***"
            )
        }

        sanitized = redactGoogleOAuthTokens(sanitized)

        return sanitized
    }

    /// 脱敏 Google OAuth 相关的敏感字面量（Antigravity 双来源认证专用）
    /// 覆盖：`ya29.` access token、`1//` refresh token、`GOCSPX-` client secret、
    /// 授权码（`code=` 查询参数）、PKCE code_verifier。
    /// - Note: 这些模式与 Claude/Codex 的 session key 形状完全不同，独立成一段，
    ///   避免和上面几段正则互相干扰。
    private static func redactGoogleOAuthTokens(_ text: String) -> String {
        var sanitized = text

        let patterns: [(pattern: String, template: String)] = [
            // access_token：ya29. 开头
            ("ya29\\.[A-Za-z0-9_-]{10,}", "ya29.***REDACTED***"),
            // refresh_token：1// 开头
            ("1//[A-Za-z0-9_-]{10,}", "1//***REDACTED***"),
            // client_secret：GOCSPX- 开头
            ("GOCSPX-[A-Za-z0-9_-]{10,}", "GOCSPX-***REDACTED***"),
            // 授权码：code=xxx 查询参数或 JSON 字段。Google 的授权码形如 `4/0AeanS0...`，
            // 字符集必须包含 `/`；查询参数的前导符可以是 `?`（首个参数）、`&`，也可能完全没有
            // 前导符（日志行开头就是 `code=...`）或前面只是空白（纯 lookbehind 强制要求
            // `"`/`'`/`&`/`?` 之一，会导致行首或空白分隔的 `code=`/`code_verifier=` 漏网）。
            // 用捕获组模板替换而不是纯 lookbehind，避免因为放宽前导符集合而误伤其它无关文本。
            ("(^|[\\s\"'&?])code[\"']?[=:]\\s?[\"']?[A-Za-z0-9._/-]{10,}", "$1code=***REDACTED***"),
            // code_verifier：JSON / query 字段
            ("(^|[\\s\"'&?])code_verifier[\"']?[=:]\\s?[\"']?[A-Za-z0-9._~-]{20,}", "$1code_verifier=***REDACTED***"),
            // JWT（如 Google `id_token`）：三段 base64url，以 `eyJ` 开头 —— 纵深防御，
            // 调用方本不应把整段 id_token 落日志，这里作为兜底
            ("eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+", "***REDACTED_JWT***")
        ]

        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: template)
        }

        return sanitized
    }
}
