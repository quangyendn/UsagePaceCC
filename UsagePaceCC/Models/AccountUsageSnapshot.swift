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

    /// 供 phase 02 的紧迫度排序使用：剩余时间越短越紧迫；
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


// MARK: - 窗口维度 / 图例行标识（P03）

/// 图表 marker 与图例行统一的窗口维度：5h / 7d。
/// Codex 目前仍是单账户（phase 02 范围），复用同一渲染路径时借用 `.fiveHour` 槽位
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

// MARK: - Codex 单账户包装（P03）

extension AccountUsageSnapshot {
    /// Codex 目前仍是单账户（phase 02 范围），但图表/图例要复用同一套账户驱动渲染路径，
    /// 因此把它包成一个「只有 fiveHour 槽位」的 snapshot；secondary/extraUsage 仍走旧的
    /// `usageData`/`codexUsageData` 驱动渲染路径，完全不受此包装影响。
    static func codexWrapper(from data: CodexUsageData?, account: Account?) -> AccountUsageSnapshot? {
        guard let primary = data?.primary else { return nil }
        // NOTE: The "can we know the elapsed ratio" plottability guard (resetsAt non-nil but
        // windowSeconds unknown/zero) intentionally lives at the CHART call site only
        // (`LinearUsageGraphView.drawAccountPoints`), not here. This wrapper is shared by both
        // the chart and the legend (`PopoverLayout.legendItems`); the legend row (percentage +
        // reset time) should always render whenever primary data exists, matching pre-P03
        // legend behavior — only the chart dot must be skipped when the x-position can't be
        // computed.
        let id = account?.id ?? codexFallbackAccountId
        return AccountUsageSnapshot(
            accountId: id,
            provider: .codex,
            displayName: account?.displayName ?? "Codex",
            color: account?.color ?? AccountColor.deterministicDefault(for: id),
            fiveHour: WindowUsage(
                percentage: primary.percentage,
                resetsAt: primary.resetsAt,
                windowSeconds: primary.windowSeconds
            ),
            sevenDay: nil,
            errorMessage: nil
        )
    }

    /// 没有已知 Codex 账户时的稳定占位 id（全 `C` 十六进制，恒定不变，不会与真实账户 UUID 冲突的概率极高）。
    private static var codexFallbackAccountId: UUID {
        UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC") ?? UUID()
    }
}
