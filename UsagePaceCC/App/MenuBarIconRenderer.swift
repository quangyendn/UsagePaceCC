//
//  MenuBarIconRenderer.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2025-12-02.
//  Copyright © 2025 f-is-h. All rights reserved.
//

import SwiftUI
import AppKit

/// 菜单栏图标渲染器
/// 负责所有图标的绘制逻辑，支持彩色和单色两种模式
/// 从 MenuBarUI 中提取以实现职责分离
class MenuBarIconRenderer {
    
    // MARK: - Settings Reference
    
    /// 用户设置实例
    private let settings: UserSettings
    /// 菜单栏品牌图标尺寸
    private let providerBrandIconSize: CGFloat = 16
    /// 菜单栏指标图标尺寸
    private let metricIconSize: CGFloat = 18
    
    // MARK: - Initialization
    
    init(settings: UserSettings = .shared) {
        self.settings = settings
    }
    
    // MARK: - Public API

    /// 创建菜单栏图标
    /// - Parameters:
    /// - usageData: Claude 用量数据
    /// - codexUsageData: Codex 用量数据（nil 表示无 Codex 账号）
    /// - claudeSnapshots: 所有已保存 Claude 账户的用量快照；用于经
    /// `topUrgentAccounts` 选出最多 2 个最紧迫账户，渲染为账户组合图标（环+饼形扇区）。
    /// Codex 目前仍是单账户，图标渲染路径不受此参数影响。
    /// - hasUpdate: 是否有可用更新
    /// - button: 状态栏按钮（用于获取外观模式）
    /// - Returns: 生成的图标图像
    func createIcon(
        usageData: UsageData?,
        codexUsageData: CodexUsageData? = nil,
        claudeSnapshots: [AccountUsageSnapshot] = [],
        antigravityUsageData: AntigravityUsageData? = nil,
        hasAntigravityPrimary: Bool = false,
        hasAntigravitySecondary: Bool = false,
        hasUpdate: Bool,
        button: NSStatusBarButton?
    ) -> NSImage {
        // 确定单色/彩色模式
        let isMonochrome: Bool
        if let data = usageData {
            let canUseColor = settings.canUseColoredTheme(usageData: data)
            let forceMonochrome = !canUseColor && settings.iconStyleMode != .monochrome
            isMonochrome = settings.iconStyleMode == .monochrome || forceMonochrome
        } else {
            isMonochrome = settings.iconStyleMode == .monochrome
        }

        let hasCodex = codexUsageData != nil
        // 自定义模式下的 0% 占位快照会在这里被注入；`hasAntigravity` 必须建立在占位注入之后，
        // 否则「刚添加账户、尚未拉到数据」这一帧会被误判为「未配置」，图标短暂消失。
        // `antigravityUsageData` 是 `settings.currentAntigravityAccountId` 对应的那一份
        // （由 `MenuBarManager` 从 `antigravityUsageByAccount` 查出并传入——
        // 没有跨账户合并的单值可用，菜单栏字形只反映当前选中账户，与账户子菜单切换保持一致）。
        let antigravityRenderSnapshots = antigravityGlyphSnapshots(from: antigravityUsageData)
        let hasAntigravity = !antigravityRenderSnapshots.isEmpty

        // 三个 Provider 都没有可渲染内容时，保留旧有的默认图标兜底路径（未配置任何账号，
        // 或 Claude 数据尚未加载完成且其余 Provider 也未激活）。
        guard usageData != nil || hasCodex || hasAntigravity else {
            let size = NSSize(width: 22, height: 22)
            let defaultIcon: NSImage
            if settings.iconDisplayMode == .none {
                defaultIcon = createMenuBarDividerIcon(isMonochrome: isMonochrome)
            } else {
                defaultIcon = isMonochrome ?
                    createCircleTemplateImage(percentage: 0, size: size, button: button, removeBackground: true) :
                    createCircleImage(percentage: 0, size: size, button: button, removeBackground: true)
            }
            if hasUpdate { return addBadgeToImage(defaultIcon) }
            return defaultIcon
        }

        let allTypes = settings.getActiveDisplayTypes(
            usageData: usageData,
            codexUsageData: codexUsageData,
            hasAntigravityPrimary: hasAntigravityPrimary,
            hasAntigravitySecondary: hasAntigravitySecondary
        )

        var icon: NSImage

        switch settings.iconDisplayMode {
        case .none:
            icon = createMenuBarDividerIcon(isMonochrome: isMonochrome)

        case .iconOnly:
            icon = createIconOnlyIcon(
                usageData: usageData,
                hasCodex: hasCodex,
                hasAntigravity: hasAntigravity,
                isMonochrome: isMonochrome
            )

        case .percentageOnly, .both:
            icon = createGroupedIcon(
                usageData: usageData,
                codexUsageData: codexUsageData,
                claudeSnapshots: claudeSnapshots,
                antigravityRenderSnapshots: antigravityRenderSnapshots,
                allTypes: allTypes,
                isMonochrome: isMonochrome,
                button: button
            )
        }

        if hasUpdate { icon = addBadgeToImage(icon) }
        return icon
    }

    // MARK: - Provider-Group Icon Creation 
    //
    // 取代原来的 Claude-only / Codex-only / multi 三条手写分支（每条都各自重复一遍
    // `iconDisplayMode` 的 4 路 switch）：按 `settings.activeProviders` 顺序（Claude → Codex →
    // Antigravity）组装每个 Provider 的指标图标分组，分隔线/品牌图标的插入规则从「Claude→Codex
    // 之间插一次」泛化为「任意两个相邻的非空分组之间插一次」。`isMonochrome`/`hasUpdate` 仍然只在
    // `createIcon` 里应用一次，不在分组循环内重复。

    /// `.iconOnly` 模式：只显示品牌图标，不显示任何指标字形。品牌图标的"该 Provider 是否出现"
    /// 判据与 `.percentageOnly`/`.both` 保持一致——Claude 看 `usageData`、Codex 看
    /// `codexUsageData`、Antigravity 看是否有可渲染的快照（含自定义模式下的占位快照）。
    private func createIconOnlyIcon(usageData: UsageData?, hasCodex: Bool, hasAntigravity: Bool, isMonochrome: Bool) -> NSImage {
        var icons: [NSImage] = []
        for provider in settings.activeProviders {
            switch provider {
            case .claude:
                guard usageData != nil else { continue }
                let iconName = isMonochrome ? "AppIconReverse" : "AppIcon"
                if let copy = ImageHelper.createSquareIcon(named: iconName, size: providerBrandIconSize, isTemplate: isMonochrome) {
                    icons.append(copy)
                }
            case .codex:
                guard hasCodex else { continue }
                if let brand = createProviderBrandIcon(.codex, isMonochrome: isMonochrome, size: providerBrandIconSize) {
                    icons.append(brand)
                }
            case .antigravity:
                guard hasAntigravity else { continue }
                if let brand = createProviderBrandIcon(.antigravity, isMonochrome: isMonochrome, size: providerBrandIconSize) {
                    icons.append(brand)
                }
            }
        }

        let icon: NSImage
        if icons.isEmpty {
            icon = createSimpleCircleIcon()
        } else if icons.count == 1 {
            // 单 Provider 时直接返回该品牌图标本身，保持旧有的 Claude-only/Codex-only 行为
            // （不经过 `combineIcons` 重新铺一张画布）。
            icon = icons[0]
        } else {
            icon = combineIcons(icons, spacing: settings.isMultiProviderActive ? 2.0 : 3.0, height: metricIconSize)
        }
        icon.isTemplate = isMonochrome
        return icon
    }

    /// `.percentageOnly`/`.both` 模式：按 Provider 分组组装指标图标 + （`.both` 下的）品牌图标，
    /// 组与组之间在 `.percentageOnly` 下插入一条分隔线（`.both` 下用品牌图标本身分隔，不需要
    /// 额外分隔线）。
    private func createGroupedIcon(
        usageData: UsageData?,
        codexUsageData: CodexUsageData?,
        claudeSnapshots: [AccountUsageSnapshot],
        antigravityRenderSnapshots: [AccountUsageSnapshot],
        allTypes: [LimitType],
        isMonochrome: Bool,
        button: NSStatusBarButton?
    ) -> NSImage {
        var groups: [(provider: ProviderType, metrics: [NSImage])] = []

        for provider in settings.activeProviders {
            switch provider {
            case .claude:
                guard let data = usageData else { continue }
                let claudeTypes = allTypes.filter { $0.provider == .claude }
                var claudeIcons = createAccountGlyphIcons(from: claudeSnapshots, showFiveHour: claudeTypes.contains(.fiveHour), showSevenDay: claudeTypes.contains(.sevenDay), button: button, isMonochrome: isMonochrome)
                let remainingClaudeTypes = claudeTypes.filter { $0 != .fiveHour && $0 != .sevenDay }
                claudeIcons.append(contentsOf: remainingClaudeTypes.compactMap { createIconForType($0, data: data, isMonochrome: isMonochrome, button: button) })
                groups.append((.claude, claudeIcons))

            case .codex:
                guard let codex = codexUsageData else { continue }
                let codexTypes = allTypes.filter { $0.provider == .codex }
                groups.append((.codex, buildCodexIcons(codex: codex, types: codexTypes, isMonochrome: isMonochrome, button: button)))

            case .antigravity:
                guard !antigravityRenderSnapshots.isEmpty else { continue }
                let antigravityTypes = allTypes.filter { $0.provider == .antigravity }
                groups.append((.antigravity, buildAntigravityIcons(snapshots: antigravityRenderSnapshots, types: antigravityTypes, isMonochrome: isMonochrome, button: button)))
            }
        }

        var icons: [NSImage] = []
        var previousGroupHadIcons = false
        for group in groups {
            if settings.iconDisplayMode == .both {
                // `.both`：当活跃 Provider 不止一个时，只在该 Provider 分组确实有指标字形时才
                // 附带品牌图标——这一段镜像旧的**多 Provider**路径（旧路径把品牌图标附加条件绑定
                // 在 `group.metrics` 非空上），此前这里对 `groups` 里的每个 Provider 都无条件附加
                // 品牌图标，只要该 Provider 处于活跃状态（如 Claude+Codex 用户在 `.custom` 模式下
                // 只勾了 Claude 的类型），就会给没有任何指标字形的 Codex 凭空画一个孤零零的品牌
                // 图标；旧代码的行为是"该分组有内容才出现"，必须保持像素级一致，否则已有用户的
                // 菜单栏会变样。
                // 但当只有**单一** Provider 活跃时，旧的单 Provider 路径
                // （`createCombinedIconWithAppIcon`/`createCodexOnlyIcon`）无条件展示品牌图标，
                // 即使一个指标字形都没有——`allIcons = [appIconCopy]` 先于任何指标图标被塞入，
                // `icons.count == 1` 时直接返回那个"仅品牌图标"的单元素数组。对单 Provider 场景
                // 套用多 Provider 的空分组守卫，会让"该 Provider 已选中但零个指标类型"（例如
                // 用户只勾了 `.codexPrimary`，随后移除了唯一的 Codex 账户，只剩 Claude 且零个
                // Claude 类型）落回 `icons.isEmpty` → 18×18 纯圆点，而不是旧版的品牌图标，
                // 这会是一次可见的界面倒退。
                if groups.count > 1 {
                    guard !group.metrics.isEmpty else { continue }
                }
                if let brand = createProviderBrandIcon(group.provider, isMonochrome: isMonochrome, size: providerBrandIconSize) {
                    icons.append(brand)
                }
                icons.append(contentsOf: group.metrics)
            } else if settings.iconDisplayMode == .percentageOnly {
                guard !group.metrics.isEmpty else { continue }
                if previousGroupHadIcons {
                    // 泛化后的分隔规则：任意两个相邻的非空分组之间插一条分隔线
                    // （原代码是 Claude→Codex 之间的一次性 `if`，这里改为通用规则以支持任意
                    // 数量的 Provider）。
                    icons.append(createMenuBarDividerIcon(isMonochrome: isMonochrome))
                }
                icons.append(contentsOf: group.metrics)
                previousGroupHadIcons = true
            }
        }

        let icon: NSImage
        if icons.isEmpty {
            icon = createSimpleCircleIcon()
        } else if icons.count == 1 {
            icon = icons[0]
        } else {
            icon = combineIcons(icons, spacing: settings.isMultiProviderActive ? 2.0 : 3.0, height: metricIconSize)
        }
        icon.isTemplate = isMonochrome
        return icon
    }

    /// 构建 Codex 指标图标列表
    /// - Note: `.codexPrimary`/`.codexSecondary`（5h/7d 等效窗口）与 Claude 共用同一套账户组合
    /// 图标机制（`createAccountGlyphIcons`，外圈进度环 + 内圈饼形扇区，账户颜色渲染）；
    /// `.codexExtraUsage` 是独立的六边形形状，不受此统一影响，仍走 `createCodexIcon`。
    private func buildCodexIcons(codex: CodexUsageData, types: [LimitType], isMonochrome: Bool, button: NSStatusBarButton?) -> [NSImage] {
        let showPlaceholder = settings.displayMode == .custom

        var icons: [NSImage] = []
        let showPrimary = types.contains(.codexPrimary)
        let showSecondary = types.contains(.codexSecondary)
        if showPrimary || showSecondary {
            let snapshots = codexGlyphSnapshots(from: codex)
            icons.append(contentsOf: createAccountGlyphIcons(
                from: snapshots,
                showFiveHour: showPrimary,
                showSevenDay: showSecondary,
                button: button,
                isMonochrome: isMonochrome
            ))
        }

        if types.contains(.codexExtraUsage) {
            let percentage: Double?
            if let extra = codex.extraUsage, extra.enabled {
                percentage = extra.percentage
            } else if showPlaceholder {
                percentage = 0
            } else {
                percentage = nil
            }
            if let percentage {
                if let icon = createCodexIcon(type: .codexExtraUsage, percentage: percentage, isMonochrome: isMonochrome, button: button) {
                    icons.append(icon)
                }
            }
        }

        return icons
    }

    /// 把当前 Codex 用量数据包装成账户组合图标所需的 snapshot 数组。
    /// Codex 目前仍是单账户，但写成数组以便未来扩展为多账户时无需改动渲染路径；
    /// `showPlaceholder`（自定义模式下账户尚无数据时）与旧的 `buildCodexIcons` 占位行为一致，
    /// 通过在自定义模式下即使 `codexWrapper` 返回 nil（无 primary 数据）也兜底一个 0% snapshot 实现。
    private func codexGlyphSnapshots(from codex: CodexUsageData) -> [AccountUsageSnapshot] {
        let account = settings.currentCodexAccount
        if let snapshot = AccountUsageSnapshot.codexWrapper(from: codex, account: account) {
            return [snapshot]
        }
        guard settings.displayMode == .custom else { return [] }
        let id = account?.id ?? Self.codexPlaceholderAccountId
        return [AccountUsageSnapshot(
            accountId: id,
            provider: .codex,
            displayName: account?.displayName ?? "Codex",
            color: account?.color ?? AccountColor.deterministicDefault(for: id),
            fiveHour: WindowUsage(percentage: 0, resetsAt: nil, windowSeconds: nil),
            sevenDay: WindowUsage(percentage: 0, resetsAt: nil, windowSeconds: nil),
            errorMessage: nil
        )]
    }

    /// 没有已知 Codex 账户时的稳定占位 id（与 `AccountUsageSnapshot.codexFallbackAccountId` 同一常量，
    /// 全 `C` 十六进制，恒定不变），用于自定义模式下的 0% 占位 snapshot。
    private static var codexPlaceholderAccountId: UUID {
        UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC") ?? UUID()
    }

    /// 构建 Antigravity 指标图标列表。
    /// - Note: 与 `buildCodexIcons` 不同——Antigravity 没有额度/信用等价物
    /// （`retrieveUserQuotaSummary` 的响应里没有这个字段），所以这里只有一段：
    /// 外圈进度环 + 内圈饼形扇区，走与 Claude/Codex 相同的账户组合图标机制
    /// （`createAccountGlyphIcons`）。
    private func buildAntigravityIcons(snapshots: [AccountUsageSnapshot], types: [LimitType], isMonochrome: Bool, button: NSStatusBarButton?) -> [NSImage] {
        let showPrimary = types.contains(.antigravityPrimary)
        let showSecondary = types.contains(.antigravitySecondary)
        guard showPrimary || showSecondary else { return [] }
        return createAccountGlyphIcons(from: snapshots, showFiveHour: showPrimary, showSevenDay: showSecondary, button: button, isMonochrome: isMonochrome)
    }

    /// 把「当前选中账户的那一份 `AntigravityUsageData`」包装成账户组合图标所需的 snapshot 数组
    /// —— 与 `codexGlyphSnapshots` 同一形状（`DataRefreshManager` 没有导出跨账户合并的单值
    /// `antigravityUsageData` 属性；菜单栏字形只反映
    /// `settings.currentAntigravityAccountId` 选中的那个账户，与账户子菜单切换保持一致）。
    /// `showPlaceholder`（自定义模式下账户尚无数据时）与
    /// `codexGlyphSnapshots` 的占位行为一致。
    private func antigravityGlyphSnapshots(from usage: AntigravityUsageData?) -> [AccountUsageSnapshot] {
        let account = settings.currentAntigravityAccount
        if let account, let snapshot = AccountUsageSnapshot.antigravitySnapshot(from: usage, account: account) {
            return [snapshot]
        }
        // `account == nil` 意味着**没有任何** Antigravity 账户——这与 Codex 的等价占位路径不同：
        // `codexGlyphSnapshots` 只能从 `buildCodexIcons` 内部到达，调用方早已保证
        // `codexUsageData != nil`（也就是至少有一个 Codex 账户）；这里的 `antigravityGlyphSnapshots`
        // 却是从 `createIcon` 顶层无条件调用的，用来计算 `hasAntigravity`。此前只要
        // `displayMode == .custom` 就无条件伪造一个 0% 占位 snapshot，会让完全没有配置
        // Antigravity 的用户在 Claude 数据尚未加载（启动瞬间）或持续报错、且没有 Codex 时，
        // `hasAntigravity` 恒为 true，图标从旧的 22×22 0% 进度环兜底退化成 18×18 的
        // `createSimpleCircleIcon()`。占位 snapshot 必须仅在
        // "确实存在至少一个 Antigravity 账户，只是这个账户还没有可渲染的数据"时才出现。
        guard let account, settings.displayMode == .custom else { return [] }
        return [AccountUsageSnapshot(
            accountId: account.id,
            provider: .antigravity,
            displayName: account.displayName,
            color: account.color,
            fiveHour: WindowUsage(percentage: 0, resetsAt: nil, windowSeconds: nil),
            sevenDay: WindowUsage(percentage: 0, resetsAt: nil, windowSeconds: nil),
            errorMessage: nil
        )]
    }

    /// 创建 Provider 品牌图标（用于多 Provider 模式下的视觉分组）
    private func createProviderBrandIcon(_ provider: ProviderType, isMonochrome: Bool, size: CGFloat = 14) -> NSImage? {
        switch provider {
        case .claude:
            let iconName = isMonochrome ? "AppIconReverse" : "AppIcon"
            return ImageHelper.createSquareIcon(named: iconName, size: size, isTemplate: isMonochrome)
        case .codex:
            let iconName = isMonochrome ? "CodexIconReverse" : "CodexIcon"
            return ImageHelper.createSquareIcon(named: iconName, size: size, isTemplate: isMonochrome, sourceInset: isMonochrome ? 0 : 2)
        case .antigravity:
            // `AntigravityIcon` / `AntigravityIconReverse` ship in the Asset Catalog.
            // `createSquareIcon` still falls back to nil if the asset is ever missing;
            // the caller (`createIcon`'s brand-icon grouping logic) already treats this as
            // `if let brand = ...`, so a missing asset would just skip the brand icon (metric
            // icons still render normally) rather than crash or show a placeholder.
            let iconName = isMonochrome ? "AntigravityIconReverse" : "AntigravityIcon"
            return ImageHelper.createSquareIcon(named: iconName, size: size, isTemplate: isMonochrome, sourceInset: isMonochrome ? 0 : 2)
        }
    }

    // MARK: - Icon Drawing - Colored Mode (彩色模式)

    private func createCircleImage(percentage: Double, size: NSSize, colorOverride: NSColor? = nil, useDashedStyle: Bool = false, button: NSStatusBarButton?, removeBackground: Bool = false) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let center = NSPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 2

        if !removeBackground {
            let backgroundCircle = NSBezierPath()
            backgroundCircle.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360, clockwise: false)
            NSColor.white.withAlphaComponent(0.5).setFill()
            backgroundCircle.fill()
        }

        NSColor.gray.withAlphaComponent(0.5).setStroke()
        let backgroundPath = NSBezierPath()
        backgroundPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360, clockwise: false)
        backgroundPath.lineWidth = 1.5

        // Codex secondary 限制使用虚线以区分实线圆（Claude 5h/7d 的虚线区分已被 P05 的
        // pie-wedge 内圈取代，仅 Codex 仍走这条独立圆环渲染路径）
        if useDashedStyle {
            let dashPattern: [CGFloat] = [3, 1]
            backgroundPath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        }

        backgroundPath.stroke()

        let color = colorOverride ?? UsageColorScheme.fiveHourColorAdaptive(percentage, for: button)

        drawProgressRing(in: NSRect(origin: .zero, size: size), percentage: percentage, color: color, lineWidth: 2.5)

        let fontSize: CGFloat = percentage >= 100 ? size.width * 0.275 : size.width * 0.4
        let font = NSFont.systemFont(ofSize: fontSize, weight: percentage >= 100 ? .bold : .semibold)
        let text = "\(Int(percentage))"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraphStyle]
        let textSize = text.size(withAttributes: attrs)
        let textOrigin = NSPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2)
        text.draw(at: textOrigin, withAttributes: attrs)

        image.unlockFocus()
        return image
    }

    // MARK: - Icon Drawing - Template Mode (单色模式)

    private func createCircleTemplateImage(percentage: Double, size: NSSize, useSevenDayStyle: Bool = false, button: NSStatusBarButton? = nil, removeBackground: Bool = false) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let center = NSPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 2

        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        let backgroundPath = NSBezierPath()
        backgroundPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360, clockwise: false)
        backgroundPath.lineWidth = 1.5

        // Codex secondary 限制使用虚线以区分实线圆
        if useSevenDayStyle {
            let dashPattern: [CGFloat] = [3, 1]
            backgroundPath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        }

        backgroundPath.stroke()

        drawProgressRing(in: NSRect(origin: .zero, size: size), percentage: percentage, color: NSColor.labelColor, lineWidth: 2.5)

        let fontSize: CGFloat = percentage >= 100 ? size.width * 0.275 : size.width * 0.4
        let font = NSFont.systemFont(ofSize: fontSize, weight: percentage >= 100 ? .bold : .semibold)
        let text = "\(Int(percentage))"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraphStyle]
        let textSize = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2), withAttributes: attrs)

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - Shared Ring / Wedge Drawing Helpers 

    /// 提取自 `createCircleImage`/`createCircleTemplateImage` 的外圈弧线描边逻辑：
    /// 保留原有的圆头端点角度修正数学（cap-angle correction），供彩色/单色圆环
    /// 以及新的账户组合图标（`createAccountGlyph`）共用，避免重复实现。
    /// - Parameters:
    /// - rect: 图标绘制区域（正方形），圆心与半径均从此推导
    /// - percentage: 使用百分比 (0-100+)
    /// - color: 描边颜色
    /// - lineWidth: 描边宽度
    private func drawProgressRing(in rect: NSRect, percentage: Double, color: NSColor, lineWidth: CGFloat) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 2

        color.setStroke()

        let progressPath = NSBezierPath()

        // 计算进度角度
        let baseAngle = CGFloat(percentage) / 100.0 * 360
        let circumference = 2 * CGFloat.pi * radius  // 圆周长
        let capAngle = (lineWidth / circumference) * 360  // 圆头延伸对应的角度

        let progressAngle: CGFloat
        let startAngle: CGFloat

        if percentage >= 100 {
            // 100%: 使用完整角度和固定起点，因为 .butt 端点无延伸
            progressAngle = baseAngle
            startAngle = 90
        } else {
            // 5小时/7天限制：使用渐进式减法，保持起点固定，实现平滑增长
            // 减去的角度随百分比线性增加，在50%时完成完整减法，50%-100%显示完全精确
            progressAngle = baseAngle - capAngle * min(1.0, CGFloat(percentage / 50.0))
            startAngle = 90 - capAngle / 2 + 0.5
        }

        let endAngle = startAngle - progressAngle

        progressPath.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        progressPath.lineWidth = lineWidth
        // 100%时使用平头让圆环完美闭合，其他进度使用圆头
        progressPath.lineCapStyle = percentage >= 100 ? .butt : .round
        progressPath.stroke()
    }

    /// 绘制 7 天用量的内圈饼形扇区填充（取代旧的虚线圆环区分方式）。
    /// - Parameters:
    /// - rect: 扇区绘制区域，半径小于外圈进度环，以在环与扇区之间留出可视间隙
    /// - percentage: 使用百分比 (0-100+)；0% 时不绘制任何图形（无残留细线）
    /// - color: 填充颜色
    private func drawPieWedge(in rect: NSRect, percentage: Double, color: NSColor) {
        guard percentage > 0 else { return }

        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let clampedPercentage = min(percentage, 100)

        // 与外圈进度环起点一致：12 点钟方向（90°），顺时针增长
        let startAngle: CGFloat = 90
        let sweep = CGFloat(clampedPercentage) / 100.0 * 360
        let endAngle = startAngle - sweep

        let path = NSBezierPath()
        path.move(to: center)
        path.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        path.line(to: center)
        path.close()

        color.setFill()
        path.fill()
    }

    /// 账户紧迫度评分：取 5 小时/7 天两个窗口中百分比较高者（而非仅优先 5h），
    /// 与 phase-03 图表对每个窗口独立应用 `isNearLimit` 保持一致——5h 低但 7d 接近上限的账户
    /// 同样应触发红色警示叠加层。仅统计用户当前实际勾选展示的窗口（`showFiveHour`/`showSevenDay`），
    /// 避免为未展示的窗口触发用户看不到对应图形的警示。
    private func urgentWindowPercentage(for snapshot: AccountUsageSnapshot, showFiveHour: Bool, showSevenDay: Bool) -> Double {
        let fiveHourPct = showFiveHour ? snapshot.fiveHour?.percentage : nil
        let sevenDayPct = showSevenDay ? snapshot.sevenDay?.percentage : nil
        return max(fiveHourPct ?? 0, sevenDayPct ?? 0)
    }

    /// 在图标外边界叠加一圈近上限警示描边（红色），叠加于账户颜色之上而非替代它——
    /// 颜色承载账户身份，警示叠加层承载紧迫度。
    private func drawNearLimitOverlay(in rect: NSRect) {
        let overlayRect = rect.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(ovalIn: overlayRect)
        path.lineWidth = 1.2
        NSColor.systemRed.setStroke()
        path.stroke()
    }

    /// 提取自 `createCircleImage`/`createCircleTemplateImage` 的淡色背景「轨道」圆环：
    /// 在描边进度弧之前先画一圈完整的浅色圆，确保 0% 用量时图标仍是「一个可见的空心圆」，
    /// 而不是几乎不可见的一个小点。
    /// `dashed` 复用 `createCircleImage`/`createCircleTemplateImage` 中既有的虚线约定
    /// （`useDashedStyle`/`useSevenDayStyle`），用于单色模式下以「实线 vs 虚线」区分同形状的
    /// 两个账户图标（因为单色模式下账户颜色不可用，无法再靠颜色区分身份）。
    private func drawTrackCircle(center: NSPoint, radius: CGFloat, color: NSColor, dashed: Bool) {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360, clockwise: false)
        path.lineWidth = 1.5
        if dashed {
            let dashPattern: [CGFloat] = [3, 1]
            path.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        }
        color.setStroke()
        path.stroke()
    }

    /// 创建单个账户的组合图标：外圈 5h 进度环 + 内圈 7d 饼形扇区。
    /// 彩色模式下以账户颜色渲染（外观自适应亮度调整）；单色模式下改用 `NSColor.labelColor`
    /// 绘制并将 `image.isTemplate = true`，以便随菜单栏浅色/深色/
    /// 高亮状态反色；由于单色模式下无法再靠账户颜色区分身份，第二个账户的轨道圆环改用虚线
    /// （`useDashedTrack`，复用既有的虚线区分约定）。
    /// `showFiveHour`/`showSevenDay` 反映用户在设置中实际勾选展示的类型（finding #1）：
    /// 未勾选的窗口不绘制对应图形；若该账户在两个已勾选窗口上均无数据，返回占位图标兜底
    /// （理论上不应被 `createAccountGlyphIcons` 的前置过滤选中，这里仅作防御）。
    /// - Parameters:
    /// - snapshot: 账户用量快照
    /// - isNearLimit: 是否已临近上限（决定是否叠加警示描边）
    /// - appearance: 状态栏按钮的外观；通过 `performAsCurrentDrawingAppearance` 将其设为当前
    /// 绘制外观，使 `NSColor` 动态颜色（如 `AccountColor.swiftUIColor` 转换而来的 `NSColor`）
    /// 在 `lockFocus`/`unlockFocus` 离屏绘制期间按正确的浅色/深色变体解析——`NSImage.lockFocus()`
    /// 本身并不会随菜单栏实际外观切换当前绘制外观（默认/沿用上一次设置，通常为 Aqua 浅色），
    /// 若不显式设置，深色菜单栏下会错误解析出浅色变体的颜色（对比度不足，近乎不可见）。
    /// - showFiveHour: 用户是否勾选展示 5h 窗口
    /// - showSevenDay: 用户是否勾选展示 7d 窗口
    /// - isMonochrome: 是否为单色模式
    /// - useDashedTrack: 单色模式下是否使用虚线轨道以区分账户（通常仅第二个账户为 true）
    private func createAccountGlyph(
        snapshot: AccountUsageSnapshot,
        isNearLimit: Bool,
        appearance: NSAppearance,
        showFiveHour: Bool,
        showSevenDay: Bool,
        isMonochrome: Bool,
        useDashedTrack: Bool
    ) -> NSImage {
        let fiveHour = showFiveHour ? snapshot.fiveHour : nil
        let sevenDay = showSevenDay ? snapshot.sevenDay : nil
        guard fiveHour != nil || sevenDay != nil else {
            return createSimpleCircleIcon()
        }

        let size = NSSize(width: metricIconSize, height: metricIconSize)
        let image = NSImage(size: size)
        image.lockFocus()

        // NSImage.lockFocus() 不会随菜单栏实际外观切换当前绘制外观（默认/沿用上一次设置，
        // 通常为 Aqua 浅色）；显式调用 performAsCurrentDrawingAppearance 使下方绘制体内解析的
        // NSColor 动态颜色（如账户自定义颜色）按 appearance 参数（状态栏按钮的真实外观）
        // 正确选取浅色/深色变体，而非始终落到浅色变体。
        appearance.performAsCurrentDrawingAppearance {
            let rect = NSRect(origin: .zero, size: size)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let color: NSColor
            if isMonochrome {
                color = NSColor.labelColor
            } else {
                // AccountColor.swiftUIColor 已按浅色/深色分别调好色值，不再叠加
                // appearanceAdaptiveColor 的额外提亮，否则与弹出窗口图例/图表中
                // 直接使用同一 dark hex 的颜色产生可见色差。
                color = NSColor(snapshot.color.swiftUIColor)
            }
            let trackColor = isMonochrome ? NSColor.labelColor.withAlphaComponent(0.25) : NSColor.gray.withAlphaComponent(0.5)

            if let fiveHour = fiveHour {
                let outerRadius = min(rect.width, rect.height) / 2 - 2
                drawTrackCircle(center: center, radius: outerRadius, color: trackColor, dashed: useDashedTrack)
                drawProgressRing(in: rect, percentage: fiveHour.percentage, color: color, lineWidth: 2.5)
            }

            if let sevenDay = sevenDay {
                // 半径小于外圈进度环（外圈半径 = size/2 - 2），留出可视间隙
                let wedgeInset: CGFloat = 5.5
                let wedgeRect = rect.insetBy(dx: wedgeInset, dy: wedgeInset)
                let wedgeRadius = min(wedgeRect.width, wedgeRect.height) / 2
                drawTrackCircle(center: center, radius: wedgeRadius, color: trackColor, dashed: useDashedTrack)
                drawPieWedge(in: wedgeRect, percentage: sevenDay.percentage, color: color)
            }

            if isNearLimit {
                drawNearLimitOverlay(in: rect)
            }
        }

        image.unlockFocus()
        image.isTemplate = isMonochrome
        return image
    }

    /// 按 provider 选出最紧迫的账户（`topUrgentAccounts`，上限 2 个），并映射为组合图标数组。
    /// - `types` 是用户当前实际勾选展示的类型（自定义模式下可能仅勾选 5h 或仅勾选 7d，
    /// 甚至两者都未勾选）：两者都未勾选时直接返回空数组，不为该账户组渲染任何图形。
    /// - 先按「在已勾选窗口上是否有真实数据」过滤快照，确保两个窗口均无数据
    /// （拉取失败/尚未加载）的账户不会因为可用账户不足 `limit` 而占据一个图标槽位、
    /// 渲染出无意义的占位圆；`createAccountGlyph` 内部的防御性 guard 仍保留作为兜底，
    /// 但不再作为主要过滤手段。
    private func createAccountGlyphIcons(
        from snapshots: [AccountUsageSnapshot],
        showFiveHour: Bool,
        showSevenDay: Bool,
        button: NSStatusBarButton?,
        isMonochrome: Bool
    ) -> [NSImage] {
        guard !snapshots.isEmpty else { return [] }
        guard showFiveHour || showSevenDay else { return [] }

        let usable = snapshots.filter { snapshot in
            (showFiveHour && snapshot.fiveHour != nil) || (showSevenDay && snapshot.sevenDay != nil)
        }
        guard !usable.isEmpty else { return [] }

        let appearance = button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return topUrgentAccounts(from: usable, limit: 2).enumerated().map { index, snapshot in
            let urgentPct = urgentWindowPercentage(for: snapshot, showFiveHour: showFiveHour, showSevenDay: showSevenDay)
            let isNearLimit = UsageColorScheme.isNearLimit(percentage: urgentPct)
            return createAccountGlyph(
                snapshot: snapshot,
                isNearLimit: isNearLimit,
                appearance: appearance,
                showFiveHour: showFiveHour,
                showSevenDay: showSevenDay,
                isMonochrome: isMonochrome,
                useDashedTrack: isMonochrome && index == 1
            )
        }
    }

    // MARK: - Utility Icons

    /// 创建简单圆形图标（备用）
    private func createSimpleCircleIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(x: 3, y: 3, width: 12, height: 12)
        let path = NSBezierPath(ovalIn: rect)

        NSColor.labelColor.setStroke()
        path.lineWidth = 2.0
        path.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// 在图标上添加徽章（小红点）
    private func addBadgeToImage(_ baseImage: NSImage) -> NSImage {
        let size = baseImage.size
        let expandedSize = NSSize(width: size.width + 2.5, height: size.height + 2.5)
        let badgedImage = NSImage(size: expandedSize)

        badgedImage.lockFocus()
        baseImage.draw(in: NSRect(origin: .zero, size: size))

        let badgeRadius: CGFloat = 2.0
        let badgeDiameter = badgeRadius * 2
        let badgeX = expandedSize.width - badgeDiameter - 1.5
        let badgeY = expandedSize.height - badgeDiameter - 1.5
        let badgeRect = NSRect(x: badgeX, y: badgeY, width: badgeDiameter, height: badgeDiameter)

        NSGraphicsContext.saveGraphicsState()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()
        NSGraphicsContext.restoreGraphicsState()

        badgedImage.unlockFocus()
        badgedImage.isTemplate = baseImage.isTemplate

        return badgedImage
    }

    // MARK: - Icon Combination Methods (v2.0)

    /// 组合多个图标到单个图像
    /// - Parameters:
    /// - icons: 要组合的图标数组
    /// - spacing: 图标间距
    /// - height: 统一高度（默认18）
    /// - Returns: 组合后的图标
    private func combineIcons(_ icons: [NSImage], spacing: CGFloat = 3.0, height: CGFloat = 18) -> NSImage {
        guard !icons.isEmpty else {
            return createSimpleCircleIcon()
        }

        // 计算总宽度
        let totalWidth = icons.reduce(0) { $0 + $1.size.width } + CGFloat(icons.count - 1) * spacing
        let size = NSSize(width: totalWidth, height: height)

        let image = NSImage(size: size)
        image.lockFocus()

        var currentX: CGFloat = 0
        for icon in icons {
            let y = (height - icon.size.height) / 2  // 垂直居中
            icon.draw(at: NSPoint(x: currentX, y: y),
                     from: NSRect(origin: .zero, size: icon.size),
                     operation: .sourceOver,
                     fraction: 1.0)
            currentX += icon.size.width + spacing
        }

        image.unlockFocus()
        return image
    }

    /// 根据限制类型和数据创建单个图标
    /// - Parameters:
    /// - type: 限制类型
    /// - data: 用量数据
    /// - isMonochrome: 是否为单色模式
    /// - button: 状态栏按钮
    /// - Returns: 图标图像
    func createIconForType(
        _ type: LimitType,
        data: UsageData,
        isMonochrome: Bool,
        button: NSStatusBarButton?
    ) -> NSImage? {
        // 根据主题模式决定是否移除背景
        // colorTranslucent: 移除背景（通透）
        // colorWithBackground: 保留背景（半透明白色）
        let removeBackground = settings.iconStyleMode == .colorTranslucent

        // 在自定义模式下，即使数据为 nil 也显示占位图标（0%）
        // 在智能模式下，数据为 nil 时返回 nil
        let showPlaceholder = settings.displayMode == .custom

        switch type {
        case .fiveHour, .sevenDay:
            // Claude 的 5h/7d 圆形指标已被账户组合图标（`createAccountGlyph`，
            // 外圈进度环 + 内圈饼形扇区）取代，由 `createIcon` 单独通过
            // `createAccountGlyphIcons` 驱动，不再经由 `createIconForType` 渲染。
            return nil

        case .opusWeekly:
            let percentage = data.opus?.percentage ?? (showPlaceholder ? 0 : nil)
            guard let percentage = percentage else { return nil }
            return ShapeIconRenderer.createVerticalRectangleIcon(percentage: percentage, isMonochrome: isMonochrome, button: button, removeBackground: removeBackground)

        case .sonnetWeekly:
            let percentage = data.sonnet?.percentage ?? (showPlaceholder ? 0 : nil)
            guard let percentage = percentage else { return nil }
            return ShapeIconRenderer.createHorizontalRectangleIcon(percentage: percentage, isMonochrome: isMonochrome, button: button, removeBackground: removeBackground)

        case .extraUsage:
            let percentage: Double?
            if let extraUsage = data.extraUsage, extraUsage.enabled {
                percentage = extraUsage.percentage
            } else if showPlaceholder {
                percentage = 0
            } else {
                percentage = nil
            }
            guard let percentage = percentage else { return nil }
            return ShapeIconRenderer.createHexagonIcon(percentage: percentage, isMonochrome: isMonochrome, button: button, removeBackground: removeBackground)

        case .codexPrimary, .codexSecondary, .codexExtraUsage:
            // Codex 数据通过 createCodexIcon 独立渲染
            // createIconForType 仅处理 Claude UsageData，此处返回 nil
            return nil

        case .antigravityPrimary, .antigravitySecondary:
            // 同 Codex：Antigravity 图标由 `createAccountGlyphIcons` 单独渲染，
            // `createIconForType` 只处理 Claude `UsageData`，这里保持编译期占位、运行期无变化。
            return nil
        }
    }

    /// 根据 Codex 用量数据创建单个图标（Codex 专用）
    /// - Note: `.codexPrimary`/`.codexSecondary` 已迁移至 `createAccountGlyphIcons`（统一的
    /// 环+饼形扇区账户组合图标，见 `buildCodexIcons`），此处只保留 `.codexExtraUsage` 的
    /// 六边形渲染——那是一个独立的形状，与 5h/7d 等效窗口的环/扇区无关。
    func createCodexIcon(
        type: LimitType,
        percentage: Double,
        isMonochrome: Bool,
        button: NSStatusBarButton?
    ) -> NSImage? {
        let removeBackground = settings.iconStyleMode == .colorTranslucent

        switch type {
        case .codexExtraUsage:
            let color = UsageColorScheme.codexExtraUsageColorAdaptive(percentage, for: button)
            return ShapeIconRenderer.createHexagonIcon(percentage: percentage, isMonochrome: isMonochrome, button: button, removeBackground: removeBackground, colorOverride: color)

        default:
            return nil
        }
    }

    /// 创建轻量分隔线图标（用于"不显示图标"模式）
    private func createMenuBarDividerIcon(isMonochrome: Bool) -> NSImage {
        let width: CGFloat = 5
        let height: CGFloat = metricIconSize
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let lineRect = NSRect(x: (width - 1) / 2, y: 1, width: 1, height: height - 2)
        let linePath = NSBezierPath(rect: lineRect)
        let lineColor = isMonochrome ? NSColor.labelColor : NSColor.secondaryLabelColor
        let gradient = NSGradient(colors: [
            lineColor.withAlphaComponent(0.0),
            lineColor.withAlphaComponent(0.55),
            lineColor.withAlphaComponent(0.55),
            lineColor.withAlphaComponent(0.0)
        ])
        gradient?.draw(in: linePath, angle: 90)

        image.unlockFocus()
        if isMonochrome { image.isTemplate = true }
        return image
    }

}
