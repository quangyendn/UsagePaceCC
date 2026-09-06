//
//  AntigravityOAuthSecrets.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-09-06.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import Foundation

/// 安装型应用 OAuth 凭据。值来自 gitignore 的 `AntigravityOAuth.plist`，
/// 资源缺失时返回 nil —— 此时 Antigravity 整个 Provider 静默关闭（Auth 设置页隐藏整节 UI）。
/// - Important: 本文件不含任何字面量 client_id / client_secret。
nonisolated struct AntigravityOAuthSecrets {
    let clientId: String
    let clientSecret: String

    /// 是否已配置（等价于 `load() != nil`），供只需要"有没有"而不需要明文密钥内容的调用方
    /// 使用——例如 `AuthSettingsView.body` 在每次渲染时都要判断整节 Antigravity UI 是否显示。
    /// `static let` 只在进程生命周期内解析一次 bundle 资源，避免每次视图刷新都把 client secret
    /// 明文重新读入内存。资源内容在运行期不会改变（随构建产物打包），缓存是安全的。
    static let isConfigured: Bool = load() != nil

    /// 从 bundle 资源加载。资源不存在、无法解析、或任一字段为空，一律返回 nil。
    /// - Note: 绝不抛出错误 —— 缺资源是「未配置」的正常状态，不是异常。
    static func load(bundle: Bundle = .main) -> AntigravityOAuthSecrets? {
        guard let url = bundle.url(forResource: "AntigravityOAuth", withExtension: "plist"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let clientId = plist["clientId"] as? String,
              let clientSecret = plist["clientSecret"] as? String,
              !clientId.isEmpty, !clientSecret.isEmpty else {
            return nil
        }

        return AntigravityOAuthSecrets(clientId: clientId, clientSecret: clientSecret)
    }
}
