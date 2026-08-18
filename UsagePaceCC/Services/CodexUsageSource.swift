//
//  CodexUsageSource.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-08-17.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import Foundation

/// Codex 用量来源的统一接口。
///
/// 这里的"接缝"是整个 fetch 流程，而不仅仅是凭据——endpoint、headers、response shape
/// 三者都随来源而不同（CLI vs Browser），详见 plan.md「Dual-Source Arbitration」。
/// - Important: 恰好两个实现（`CodexCLIUsageSource` / `CodexBrowserUsageSource`），
///   不做注册表、不做动态扩展。
protocol CodexUsageSource {
    /// 该实现对应的凭据来源
    var source: CodexSource { get }
    /// 该来源当前是否已配置凭据（不代表凭据一定有效，例如 CLI token 可能已过期）
    var isConfigured: Bool { get }
    /// 发起一次完整的用量请求（凭据获取 + 用量请求 + 解码）
    func fetchUsage(session: URLSession, completion: @escaping (Result<CodexUsageData, Error>) -> Void)
    /// 取消该来源当前所有进行中的请求
    func cancel()
}
