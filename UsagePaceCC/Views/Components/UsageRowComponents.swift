//
//  UsageRowComponents.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2025-12-18.
//  Copyright © 2025 f-is-h. All rights reserved.
//

import SwiftUI

// MARK: - Mini Progress Icon Component

/// 迷你进度图标（带百分比数字和进度弧，与菜单栏图标风格一致）
struct MiniProgressIcon: View {
    let type: LimitType
    let color: Color
    let percentage: Double
    let size: CGFloat = 22

    var body: some View {
        Canvas { context, canvasSize in
            let lineWidth: CGFloat = 2.2
            let rect = CGRect(origin: .zero, size: canvasSize)
            let fullPath = IconShapePaths.pathForLimitType(type, in: rect)

            // 1. 形状边框（彩色）
            context.stroke(fullPath, with: .color(color), lineWidth: lineWidth)

            // 2. 百分比数字（居中）
            let fontSize = percentage >= 100 ? canvasSize.width * 0.28 : canvasSize.width * 0.38
            let text = Text("\(Int(percentage))")
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(color)
            context.draw(text, at: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Unified Limit Row Component

/// 统一的限制行组件（支持所有 Claude 和 Codex 限制类型）
struct UnifiedLimitRow: View {
    /// Legacy single-account path (unchanged by P03) — nil when constructed via `init(accountItem:showRemainingMode:)`.
    var type: LimitType? = nil
    var data: UsageData? = nil
    var codexData: CodexUsageData? = nil
    /// New account-driven path (P03): 5h/7d Claude rows + the Codex primary-wrapped row.
    var accountItem: LegendRowItem? = nil
    let showRemainingMode: Bool

    init(type: LimitType, data: UsageData? = nil, codexData: CodexUsageData? = nil, showRemainingMode: Bool) {
        self.type = type
        self.data = data
        self.codexData = codexData
        self.accountItem = nil
        self.showRemainingMode = showRemainingMode
    }

    /// New account-driven row (P03): label = `{first 5 chars of displayName} {5h|7d}`, swatch =
    /// `snapshot.color.swiftUIColor`, value = `{percentage}% · {MM/dd HH:mm}` (fixed 24h format).
    init(accountItem: LegendRowItem, showRemainingMode: Bool) {
        self.type = nil
        self.data = nil
        self.codexData = nil
        self.accountItem = accountItem
        self.showRemainingMode = showRemainingMode
    }

    var body: some View {
        HStack(spacing: 8) {
            // 图标（含百分比数字和进度弧）；账户驱动行在接近限额时叠加红色警示环（code-review
            // fix 5），与图表点 `LinearUsageGraphView.drawAccountDot` 的红环叠加同一套视觉语言——
            // 账户色仍是主色，红环只是叠加的紧迫度信号，不是替换。
            MiniProgressIcon(type: iconShapeType, color: swatchColor, percentage: percentageValue ?? 0)
                .overlay(
                    Circle()
                        .stroke(Color.red, lineWidth: 1.5)
                        .padding(-2)
                        .opacity(isNearLimit ? 1 : 0)
                )

            // 限制类型名称（账户驱动行：`{%}% {5字符名} {窗口}`，percent 已并入 limitName 前缀；
            // 固定字号、不做 minimumScaleFactor 收缩——5 字符名截断 + 短窗口标签已经把总长度
            // 控制在可预测范围内，legacy 行仍保留原有的自适应缩放）
            if accountItem != nil {
                Text(limitName)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else {
                Text(limitName)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }

            Spacer(minLength: 8)

            // 右侧：重置时间或剩余额度（账户驱动行：仅 `· {date}`，百分比已并入 limitName）
            if accountItem != nil {
                Text(displayValue)
                    .font(.system(size: 12))
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .lineLimit(1)
                    .id(showRemainingMode ? "remaining" : "reset")  // 强制识别为不同视图
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
            } else {
                Text(displayValue)
                    .font(.system(size: 12))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .id(showRemainingMode ? "remaining" : "reset")  // 强制识别为不同视图
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 12)
        .background(Color.dynamic(light: "#e1e0d9", dark: "#2c2c2a").opacity(0.4))
        .cornerRadius(8)
    }

    // MARK: - Computed Properties

    /// Icon shape passed to `MiniProgressIcon` — account-driven rows reuse the 5h/7d shapes keyed by
    /// `window`, legacy rows keep using their own `type`.
    private var iconShapeType: LimitType {
        if let accountItem {
            // Mirror `limitName`'s provider-aware branching (code-review fix 4): a Codex account row
            // must use the Codex icon shape (`.codexPrimary`, same as the pre-existing legacy Codex
            // path used), not Claude's fiveHour/sevenDay shape just because it borrows the `.fiveHour`
            // window slot (see `AccountUsageSnapshot.codexWrapper`).
            if accountItem.snapshot.provider == .codex {
                return .codexPrimary
            }
            return accountItem.window == .fiveHour ? .fiveHour : .sevenDay
        }
        return type ?? .fiveHour
    }

    /// Whether this row's swatch should carry the near-limit warning ring (code-review fix 5).
    /// Only meaningful for account-driven rows — legacy rows already color the whole swatch by
    /// percentage via `iconColor`'s per-`LimitType` palette combined with `MiniProgressIcon`'s
    /// percentage-driven arc, so they don't need a separate danger signal.
    private var isNearLimit: Bool {
        guard accountItem != nil, let percentage = percentageValue else { return false }
        return UsageColorScheme.isNearLimit(percentage: percentage)
    }

    /// Swatch color: account-driven rows (P03) use `snapshot.color.swiftUIColor` (unifies legend swatch
    /// and chart dot color); legacy rows keep the untouched percentage/type-driven `iconColor` below.
    private var swatchColor: Color {
        if let accountItem {
            return accountItem.snapshot.color.swiftUIColor
        }
        return iconColor
    }

    private var limitName: String {
        if let accountItem {
            // percent-first, fixed 2-digit width（"5%"/"95%" 对齐一致，见 P06 fix 4）：
            // `%2d` 对单数字百分比左侧补空格，不做零填充（零填充会把 "5%" 显示成 "05%"）。
            let percentPrefix = percentageValue.map { String(format: "%2d%%", Int($0)) } ?? "-"
            let prefix = String(accountItem.snapshot.displayName.prefix(5))
            let windowLabel: String
            if accountItem.snapshot.provider == .codex {
                // Codex 的窗口长度由 wire 决定，不能沿用 Claude 的 5h/7d 命名（见 plan.md Q4）；
                // 短格式版本，与 Claude 的 fiveHourLimitShort/sevenDayLimitShort 同样精简。
                windowLabel = L.LimitTypes.codexWindowNameShort(windowSeconds: accountItem.windowUsage?.windowSeconds)
            } else {
                windowLabel = accountItem.window == .fiveHour ? L.Usage.fiveHourLimitShort : L.Usage.sevenDayLimitShort
            }
            return "\(percentPrefix) \(prefix) \(windowLabel)"
        }

        switch type {
        case .fiveHour:
            return L.DetailRow.fiveHour
        case .sevenDay:
            return L.DetailRow.sevenDay
        // Codex 的窗口长度由 wire 决定，不能沿用 Claude 的 5h/7d 命名：本机 primary 窗口实测
        // 是 7 天，写死 "5-Hour Limit" 会让 legend 和图上的点自相矛盾（见 plan.md Q4）。
        case .codexPrimary:
            return L.LimitTypes.codexWindowName(windowSeconds: codexData?.primary?.windowSeconds)
        case .codexSecondary:
            return L.LimitTypes.codexWindowName(windowSeconds: codexData?.secondary?.windowSeconds)
        case .opusWeekly:
            return L.DetailRow.opusWeekly
        case .sonnetWeekly:
            return L.DetailRow.sonnetWeekly
        case .extraUsage:
            return L.DetailRow.extraUsage
        case .codexExtraUsage:
            return L.LimitTypes.codexExtraUsage
        case nil:
            return ""
        }
    }

    /// Legacy per-`LimitType` palette (unchanged by P03 — still the color source for the
    /// legacy single-account rows that stayed on this path).
    private var iconColor: Color {
        switch type {
        case .fiveHour:
            return .green
        case .sevenDay:
            return .purple
        case .opusWeekly:
            return .orange
        case .sonnetWeekly:
            return .blue
        case .extraUsage:
            return .pink
        case .codexPrimary:
            return Color(red: 45/255.0, green: 212/255.0, blue: 191/255.0)   // #2DD4BF
        case .codexSecondary:
            return Color(red: 96/255.0, green: 165/255.0, blue: 250/255.0)   // #60A5FA
        case .codexExtraUsage:
            return Color(red: 245/255.0, green: 158/255.0, blue: 11/255.0)    // #F59E0B
        case nil:
            return .gray
        }
    }

    private var percentageValue: Double? {
        if let accountItem {
            return accountItem.windowUsage?.percentage
        }
        switch type {
        case .fiveHour:       return data?.fiveHour?.percentage
        case .sevenDay:       return data?.sevenDay?.percentage
        case .opusWeekly:     return data?.opus?.percentage
        case .sonnetWeekly:   return data?.sonnet?.percentage
        case .extraUsage:     return data?.extraUsage?.percentage
        case .codexPrimary:   return codexData?.primary?.percentage
        case .codexSecondary: return codexData?.secondary?.percentage
        case .codexExtraUsage: return codexData?.extraUsage?.percentage
        case nil: return nil
        }
    }

    private var displayValue: String {
        if let accountItem {
            // 百分比已并入 `limitName` 前缀（P06 fix 4），这里只保留 `· {MM/dd HH:mm}`（24h，
            // locale 无关），不随 showRemainingMode 切换——新格式没有「剩余额度」变体。
            guard let resetsAt = accountItem.windowUsage?.resetsAt else { return "-" }
            return "· \(TimeFormatHelper.formatFixed(resetsAt))"
        }

        switch type {
        case nil:
            return "-"
        case .fiveHour:
            guard let fiveHour = data?.fiveHour else { return "-" }
            return showRemainingMode ? fiveHour.formattedCompactRemaining : detailCompactResetTime(fiveHour)

        case .sevenDay:
            guard let sevenDay = data?.sevenDay else { return "-" }
            return showRemainingMode ? sevenDay.formattedCompactRemaining : sevenDay.formattedCompactResetDate

        case .opusWeekly:
            guard let opus = data?.opus else { return "-" }
            return showRemainingMode ? opus.formattedCompactRemaining : opus.formattedCompactResetDate

        case .sonnetWeekly:
            guard let sonnet = data?.sonnet else { return "-" }
            return showRemainingMode ? sonnet.formattedCompactRemaining : sonnet.formattedCompactResetDate

        case .extraUsage:
            guard let extra = data?.extraUsage else { return "-" }
            return showRemainingMode ? extra.formattedRemainingAmount : extra.formattedCompactAmount

        case .codexPrimary:
            guard let limitData = codexData?.primary?.asUsageLimitData() else { return "-" }
            return showRemainingMode ? limitData.formattedCompactRemaining : detailCompactResetTime(limitData)

        case .codexSecondary:
            guard let limitData = codexData?.secondary?.asUsageLimitData() else { return "-" }
            return showRemainingMode ? limitData.formattedCompactRemaining : limitData.formattedCompactResetDate

        case .codexExtraUsage:
            guard let extra = codexData?.extraUsage else { return "-" }
            return showRemainingMode ? extra.formattedDetailRemainingAmount : extra.formattedDetailCompactAmount
        }
    }

    private func detailCompactResetTime(_ limitData: UsageData.LimitData) -> String {
        guard let resetsAt = limitData.resetsAt else {
            return "-"
        }

        var calendar = Calendar.current
        calendar.locale = UserSettings.shared.appLocale
        let timeString = TimeFormatHelper.formatTimeOnly(resetsAt)

        if calendar.isDateInToday(resetsAt) {
            return "\(L.DetailRow.today) \(timeString)"
        }
        if calendar.isDateInTomorrow(resetsAt) {
            return "\(L.UsageData.tomorrow) \(timeString)"
        }
        return TimeFormatHelper.formatDateTime(resetsAt, dateTemplate: "Md")
    }
}
