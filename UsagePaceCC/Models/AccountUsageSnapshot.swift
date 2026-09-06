//
//  AccountUsageSnapshot.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-08-27.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import Foundation

// MARK: - 时间窗口用量

/// 单个时间窗口（5h 或 7d）的用量快照；Codex 的窗口时长是数据驱动的，
/// 而非固定的 5 小时/7 天，因此保留 windowSeconds 而非写死常量。
struct WindowUsage: Codable, Equatable {
    /// 当前使用百分比，取值范围 0...100+（并非 0...1，超额场景可能超过 100）
    var percentage: Double
    /// 重置时间；nil 表示该窗口尚未开始使用（无有效重置时间）
    var resetsAt: Date?
    /// 窗口时长（秒）；nil 表示时长未知，不应臆造默认值
    var windowSeconds: TimeInterval?
    /// Provider 提供的展示元数据，并非 UI 层意义上的 tooltip——目前只有 Antigravity
    /// 填充（服务端 `group.displayName`，已做长度截断）；Claude/Codex 留 nil。
    /// 是否/如何把它呈现为 hover 提示由渲染层决定（见 `UsageRowComponents` 的 `.help` 用法），
    /// 这里只负责携带原始文案——`WindowUsage` 所有既有构造调用点不带这个参数也能继续编译。
    var sourceLabel: String? = nil

    /// 供紧迫度排序使用：剩余时间越短越紧迫；
    /// resetsAt 为 nil 时无法计算剩余时间，因此同样返回 nil
    var remaining: TimeInterval? {
        resetsAt?.timeIntervalSinceNow
    }
}

// MARK: - 账户用量快照

/// 承载单个账户渲染一行/两个图表点/一个图标所需的全部信息，
/// 避免图表、图例、图标各自从原始 UsageData 重复推导；
/// 刻意不包含 sessionKey 等凭据字段，仅用于展示。
struct AccountUsageSnapshot: Equatable, Identifiable {
    /// 账户唯一标识
    var accountId: UUID
    /// 账户所属的服务提供方（Claude / Codex 等）
    var provider: ProviderType
    /// 账户展示名称
    var displayName: String
    /// 账户在多账户视图中使用的颜色
    var color: AccountColor
    /// 5 小时窗口用量；nil 表示该窗口当前无活跃会话
    var fiveHour: WindowUsage?
    /// 7 天窗口用量；nil 表示该窗口当前无活跃会话
    var sevenDay: WindowUsage?
    /// 最近一次拉取该账户数据时的错误信息；nil 表示拉取无错误
    var errorMessage: String?

    var id: UUID { accountId }
}


// MARK: - 窗口维度 / 图例行标识

/// 图表 marker 与图例行统一的窗口维度：5h / 7d。
/// Codex 目前仍是单账户，复用同一渲染路径时借用 `.fiveHour` 槽位
/// 承载其唯一的 primary 窗口，真正展示的窗口名仍由 `L.LimitTypes.codexWindowName(windowSeconds:)`
/// 决定，不受这里的 case 名字影响。
enum WindowKind: String, Equatable {
    case fiveHour
    case sevenDay
}

/// 单列弹出窗口图例区域的一行：某个账户在某个窗口维度上的用量。
/// `id` 同时编码 accountId 与 window，保证 `ForEach` 身份在账户/窗口维度都稳定。
struct LegendRowItem: Identifiable, Equatable {
    var accountId: UUID
    var snapshot: AccountUsageSnapshot
    var window: WindowKind

    var id: String { "\(accountId.uuidString)-\(window.rawValue)" }

    /// 该行对应窗口的用量数据；nil 表示该窗口当前无数据（调用方应在构造前已过滤掉这种情况）。
    var windowUsage: WindowUsage? {
        switch window {
        case .fiveHour: return snapshot.fiveHour
        case .sevenDay: return snapshot.sevenDay
        }
    }
}

// MARK: - Codex 单账户包装

extension AccountUsageSnapshot {
    /// Codex 目前仍是单账户，但图表/图例要复用同一套账户驱动渲染路径，
    /// 因此把它包成一个 snapshot；fiveHour 对应 primary 窗口，sevenDay 对应 secondary 窗口；
    /// extraUsage 仍走旧的 `usageData`/`codexUsageData` 驱动渲染路径，完全不受此包装影响。
    static func codexWrapper(from data: CodexUsageData?, account: Account?) -> AccountUsageSnapshot? {
        // Build the wrapper whenever EITHER window has data. Requiring `primary` alone used to
        // drop `secondary`-only data entirely (or worse, draw a misleading 0% wedge via a
        // fallback path) — matching how Claude's per-account snapshots already tolerate one
        // window being nil.
        guard data?.primary != nil || data?.secondary != nil else { return nil }
        // NOTE: The "can we know the elapsed ratio" plottability guard (resetsAt non-nil but
        // windowSeconds unknown/zero) intentionally lives at the CHART call site only
        // (`LinearUsageGraphView.drawAccountPoints`), not here. This wrapper is shared by both
        // the chart and the legend (`PopoverLayout.legendItems`); the legend row (percentage +
        // reset time) should always render whenever primary data exists, matching pre-P03
        // legend behavior — only the chart dot must be skipped when the x-position can't be
        // computed.
        let id = account?.id ?? codexFallbackAccountId
        let primary = data?.primary
        let secondary = data?.secondary
        return AccountUsageSnapshot(
            accountId: id,
            provider: .codex,
            displayName: account?.displayName ?? "Codex",
            color: account?.color ?? AccountColor.deterministicDefault(for: id),
            fiveHour: primary.map {
                WindowUsage(
                    percentage: $0.percentage,
                    resetsAt: $0.resetsAt,
                    windowSeconds: $0.windowSeconds
                )
            },
            sevenDay: secondary.map {
                WindowUsage(
                    percentage: $0.percentage,
                    resetsAt: $0.resetsAt,
                    windowSeconds: $0.windowSeconds
                )
            },
            errorMessage: nil
        )
    }

    /// 没有已知 Codex 账户时的稳定占位 id（全 `C` 十六进制，恒定不变，不会与真实账户 UUID 冲突的概率极高）。
    private static var codexFallbackAccountId: UUID {
        UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC") ?? UUID()
    }
}

// MARK: - Antigravity 多账户快照

extension AccountUsageSnapshot {
    /// 把「每账户一份 `AntigravityUsageData`」拍成渲染层要的快照数组。
    /// - Important: Antigravity 的 OAuth 来源支持多账户，因此这里是**数组**，走的是 Claude 那条
    /// `claudeSnapshots` 路径（`DataRefreshManager.rebuildClaudeSnapshots`），而不是 Codex 的
    /// 单值 `codexWrapper`。
    /// - Important: `fiveHour` / `sevenDay` 在这里同样是**槽位名而非语义**（同 `codexWrapper` 上方
    /// 的说明）：拍平后的 bucket 0 进 `fiveHour` 槽，bucket 1 进 `sevenDay` 槽；weekly 窗口落进
    /// "5h" 槽位完全没问题——X 轴是归一化的「窗口已过去的比例」，不是绝对时间。
    /// - Important: 出错的账户保留它上一次成功拉取的数据继续渲染（同 `rebuildClaudeSnapshots`
    /// 的 Claude 行为），而不是整行消失——一个账户失败绝不能把其他账户的行挤掉，也不应造成
    /// popover 行数抖动。Provider 级错误行的规则见 `PopoverLayout.rowCount` 顶上的说明。
    /// - Note: 「能否算出 elapsed 比例」的可绘制性判断只在图表调用点做（同 Codex），这里不重复。
    static func antigravitySnapshots(
        from usageByAccount: [UUID: AntigravityUsageData],
        accounts: [Account],
        errors: [UUID: String]
    ) -> [AccountUsageSnapshot] {
        accounts.compactMap { account in
            antigravitySnapshot(
                from: usageByAccount[account.id],
                account: account,
                errorMessage: errors[account.id]
            )
        }
    }

    /// 单账户版本：与 `rebuildClaudeSnapshots` 同一形状——出错账户不再被丢弃，而是保留它
    /// 上一次成功拉取的数据（`data` 仍来自 `antigravityUsageByAccount`，失败不会清空该字典），
    /// 并把 `errorMessage` 一并带出去，行照常渲染。只有当该账户既没有
    /// 任何已知数据、也没有错误（从未拉取过）时才不产生快照。
    static func antigravitySnapshot(
        from data: AntigravityUsageData?,
        account: Account,
        errorMessage: String? = nil
    ) -> AccountUsageSnapshot? {
        let hasBuckets = data.map { !$0.buckets.isEmpty } ?? false
        guard hasBuckets || errorMessage != nil else { return nil }
        return AccountUsageSnapshot(
            accountId: account.id,
            provider: .antigravity,
            displayName: account.displayName,
            color: account.color,
            fiveHour: data?.primary.map {
                WindowUsage(
                    percentage: $0.usagePercentage,
                    resetsAt: $0.resetsAt,
                    windowSeconds: $0.windowSeconds,
                    sourceLabel: Self.cappedAntigravitySourceLabel($0.groupDisplayName)
                )
            },
            sevenDay: data?.secondary.map {
                WindowUsage(
                    percentage: $0.usagePercentage,
                    resetsAt: $0.resetsAt,
                    windowSeconds: $0.windowSeconds,
                    sourceLabel: Self.cappedAntigravitySourceLabel($0.groupDisplayName)
                )
            },
            errorMessage: errorMessage
        )
    }

    /// `sourceLabel` 长度上限（Security：`group.displayName` 是服务端可控字符串，绝不能无界渲染）。
    private static let antigravitySourceLabelMaxLength = 80

    private static func cappedAntigravitySourceLabel(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        if raw.count <= antigravitySourceLabelMaxLength { return raw }
        return String(raw.prefix(antigravitySourceLabelMaxLength)) + "…"
    }
}
