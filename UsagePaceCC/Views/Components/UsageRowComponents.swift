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
    /// 7d 行使用填充样式（与图表 7d 点一致：彩色实心填充 + 细白边），数字改白色以保证可读性；
    /// 5h 行保持原有描边样式（见 `LinearUsageGraphView.drawAccountDot` 的 `.filled`/`.outline` 区分）。
    var filled: Bool = false

    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            let fullPath = IconShapePaths.pathForLimitType(type, in: rect)

            if filled {
                // 1. 实心填充（彩色）+ 细白边，与图表 7d 点样式一致
                context.fill(fullPath, with: .color(color))
                context.stroke(fullPath, with: .color(.white.opacity(0.8)), lineWidth: 1)
            } else {
                // 1. 形状边框（彩色）
                let lineWidth: CGFloat = 2.2
                context.stroke(fullPath, with: .color(color), lineWidth: lineWidth)
            }

            // 2. 百分比数字（居中）；填充样式下用白色数字保证可读性
            let fontSize = percentage >= 100 ? canvasSize.width * 0.28 : canvasSize.width * 0.38
            let text = Text("\(Int(percentage))")
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(filled ? .white : color)
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
    /// New account-driven path : 5h/7d Claude rows + the Codex primary-wrapped row.
    var accountItem: LegendRowItem? = nil
    let showRemainingMode: Bool

    init(type: LimitType, data: UsageData? = nil, codexData: CodexUsageData? = nil, showRemainingMode: Bool) {
        self.type = type
        self.data = data
        self.codexData = codexData
        self.accountItem = nil
        self.showRemainingMode = showRemainingMode
    }

    /// New account-driven row : label = `{first 5 chars of displayName} {5h|7d}`, swatch =
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
            MiniProgressIcon(type: iconShapeType, color: swatchColor, percentage: percentageValue ?? 0, filled: isSevenDayWindow)
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
        // Hover 提示，优先级：账户当前报错的说明 > Antigravity 的 `group.displayName`
        // sourceLabel。一个账户失败后仍会带着上一次成功拉取的数据继续渲染这一行，
        // 但那份数据可能已经过期任意长时间；这里把 `snapshot.errorMessage` 接进来，
        // 让"这一行是陈旧数据、账户目前拉取失败"在 hover 时至少可被发现，而不需要新增行/改变行高
        // （MIXED 场景：部分账户失败、部分健康时不出现 provider 级错误行，
        // 但失败账户自己的行仍应有办法被看出问题）。Claude/Codex 行的 `errorMessage`/`sourceLabel`
        // 恒为 nil，不应用 `.help` 修饰符而不是应用一个空字符串——`.help("")` 会覆盖系统默认的
        // （无）提示行为，这不是同一件事。
        .optionalHelp(accountItem?.snapshot.errorMessage ?? accountItem?.windowUsage?.sourceLabel)
    }

    // MARK: - Computed Properties

    /// Icon shape passed to `MiniProgressIcon` — account-driven rows reuse the 5h/7d shapes keyed by
    /// `window`, legacy rows keep using their own `type`.
    private var iconShapeType: LimitType {
        if let accountItem {
            // Mirror `limitName`'s provider-aware branching: a Codex/Antigravity
            // account row must use its own icon shape, not Claude's fiveHour/sevenDay shape just
            // because it borrows the `.fiveHour`/`.sevenDay` window slot (see
            // `AccountUsageSnapshot.codexWrapper` / `.antigravitySnapshot`). In practice all six
            // cases currently render as the identical circle (`IconShapePaths.pathForLimitType`)
            // — so today this branching has no *visible* effect — but it keeps
            // `iconShapeType` correct/future-proof if a provider-specific shape is ever introduced,
            // and matches the already-provider-aware `limitName`/`swatchColor` branching right below.
            switch accountItem.snapshot.provider {
            case .codex:
                return .codexPrimary
            case .antigravity:
                return accountItem.window == .fiveHour ? .antigravityPrimary : .antigravitySecondary
            case .claude:
                return accountItem.window == .fiveHour ? .fiveHour : .sevenDay
            }
        }
        return type ?? .fiveHour
    }

    /// Whether this row is a 7d window (account-driven rows only) — drives the filled swatch style
    /// to match `LinearUsageGraphView.drawAccountDot`'s `.filled` (7d) vs `.outline` (5h) marker.
    private var isSevenDayWindow: Bool {
        accountItem?.window == .sevenDay
    }

    /// Whether this row's swatch should carry the near-limit warning ring.
    /// Only meaningful for account-driven rows — legacy rows already color the whole swatch by
    /// percentage via `iconColor`'s per-`LimitType` palette combined with `MiniProgressIcon`'s
    /// percentage-driven arc, so they don't need a separate danger signal.
    private var isNearLimit: Bool {
        guard accountItem != nil, let percentage = percentageValue else { return false }
        return UsageColorScheme.isNearLimit(percentage: percentage)
    }

    /// Swatch color: account-driven rows use `snapshot.color.swiftUIColor` (unifies legend swatch
    /// and chart dot color); legacy rows keep the untouched percentage/type-driven `iconColor` below.
    private var swatchColor: Color {
        if let accountItem {
            return accountItem.snapshot.color.swiftUIColor
        }
        return iconColor
    }

    private var limitName: String {
        if let accountItem {
            // percent-first, fixed 2-digit width（"5%"/"95%" 对齐一致）：
            // `%2d` 对单数字百分比左侧补空格，不做零填充（零填充会把 "5%" 显示成 "05%"）。
            let percentPrefix = percentageValue.map { String(format: "%2d%%", Int($0)) } ?? "-"
            let prefix = String(accountItem.snapshot.displayName.prefix(5))
            let windowLabel: String
            switch accountItem.snapshot.provider {
            case .codex:
                // Codex 的窗口长度由 wire 决定，不能沿用 Claude 的 5h/7d 命名；
                // 短格式版本，与 Claude 的 fiveHourLimitShort/sevenDayLimitShort 同样精简。
                windowLabel = L.LimitTypes.codexWindowNameShort(windowSeconds: accountItem.windowUsage?.windowSeconds)
            case .antigravity:
                // 静态本地化短标签：bucket 0 → Gemini, bucket 1 → 3P。
                // 服务端 `group.displayName`（如 "Claude and GPT models"）只进 tooltip，不进这里。
                windowLabel = accountItem.window == .fiveHour ? L.LimitTypes.antigravityPrimary : L.LimitTypes.antigravitySecondary
            case .claude:
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
        // 是 7 天，写死 "5-Hour Limit" 会让 legend 和图上的点自相矛盾。
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
        case .antigravityPrimary, .antigravitySecondary:
            // Antigravity 只走账户驱动路径（`accountItem` 分支，见上方 early return），此分支不可达。
            return type?.displayName ?? ""
        case nil:
            return ""
        }
    }

    /// Legacy per-`LimitType` palette (unchanged — still the color source for the
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
        case .antigravityPrimary, .antigravitySecondary:
            // 同上：这条 legacy 单值路径没有调用点会以 Antigravity 到达，因此这里的调色板值从未
            // 被实际渲染，只是让 switch 保持穷举。
            return .gray
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
        case .antigravityPrimary, .antigravitySecondary: return nil
        case nil: return nil
        }
    }

    private var displayValue: String {
        if let accountItem {
            // 百分比已并入 `limitName` 前缀，这里只保留 `· {MM/dd HH:mm}`（24h，
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

        case .antigravityPrimary, .antigravitySecondary:
            // 同上：Antigravity 只走账户驱动路径，此分支不可达。
            return "-"
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

// MARK: - Conditional `.help` Modifier

extension View {
    /// 仅在 `text` 非 nil 时应用 `.help(text)`；`.help("")` 并非"无提示"的等价写法——
    /// 它会用空字符串覆盖系统默认行为，所以这里用条件分支而不是 `.help(text ?? "")`。
    /// SwiftUI 没有 `.help(nil)` 重载。
    @ViewBuilder
    func optionalHelp(_ text: String?) -> some View {
        if let text {
            self.help(text)
        } else {
            self
        }
    }
}
