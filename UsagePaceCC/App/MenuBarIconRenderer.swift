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
    ///   - usageData: Claude 用量数据
    ///   - codexUsageData: Codex 用量数据（nil 表示无 Codex 账号）
    ///   - claudeSnapshots: 所有已保存 Claude 账户的用量快照（P05）；用于经
    ///     `topUrgentAccounts` 选出最多 2 个最紧迫账户，渲染为账户组合图标（环+饼形扇区）。
    ///     Codex 目前仍是单账户，图标渲染路径不受此参数影响。
    ///   - hasUpdate: 是否有可用更新
    ///   - button: 状态栏按钮（用于获取外观模式）
    /// - Returns: 生成的图标图像
    func createIcon(
        usageData: UsageData?,
        codexUsageData: CodexUsageData? = nil,
        claudeSnapshots: [AccountUsageSnapshot] = [],
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

        var icon: NSImage

        if let codex = codexUsageData {
            // 有 Codex 数据路径
            let allTypes = settings.getActiveDisplayTypes(usageData: usageData, codexUsageData: codex)
            let codexTypes = allTypes.filter { $0.provider == .codex }

            if settings.isMultiProviderActive, let data = usageData {
                // 双 Provider 模式
                let claudeTypes = allTypes.filter { $0.provider == .claude }
                icon = createMultiProviderIcon(data: data, codex: codex, claudeTypes: claudeTypes, codexTypes: codexTypes, claudeSnapshots: claudeSnapshots, isMonochrome: isMonochrome, button: button)
            } else {
                // Codex-only（无 Claude 账号）或降级路径
                icon = createCodexOnlyIcon(codex: codex, codexTypes: codexTypes, isMonochrome: isMonochrome, button: button)
            }
        } else {
            // Claude-only 路径（原有逻辑）
            guard let data = usageData else {
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

            let activeTypes = settings.getActiveDisplayTypes(usageData: data)

            switch settings.iconDisplayMode {
            case .percentageOnly:
                icon = createCombinedPercentageIcon(data: data, types: activeTypes, claudeSnapshots: claudeSnapshots, isMonochrome: isMonochrome, button: button)
            case .iconOnly:
                let iconName = isMonochrome ? "AppIconReverse" : "AppIcon"
                if let iconCopy = ImageHelper.createSquareIcon(named: iconName, size: providerBrandIconSize, isTemplate: isMonochrome) {
                    icon = iconCopy
                } else {
                    icon = createSimpleCircleIcon()
                }
            case .both:
                icon = createCombinedIconWithAppIcon(data: data, types: activeTypes, claudeSnapshots: claudeSnapshots, isMonochrome: isMonochrome, button: button)
            case .none:
                icon = createMenuBarDividerIcon(isMonochrome: isMonochrome)
            }
        }

        if hasUpdate { icon = addBadgeToImage(icon) }
        return icon
    }

    // MARK: - Multi-Provider Icon Creation

    /// 双 Provider 模式图标：[Claude 品牌] + [Claude 指标] + [Codex 品牌] + [Codex 指标]
    private func createMultiProviderIcon(
        data: UsageData,
        codex: CodexUsageData,
        claudeTypes: [LimitType],
        codexTypes: [LimitType],
        claudeSnapshots: [AccountUsageSnapshot],
        isMonochrome: Bool,
        button: NSStatusBarButton?
    ) -> NSImage {
        var icons: [NSImage] = []

        switch settings.iconDisplayMode {
        case .iconOnly:
            // 只显示品牌图标
            let iconName = isMonochrome ? "AppIconReverse" : "AppIcon"
            if let copy = ImageHelper.createSquareIcon(named: iconName, size: providerBrandIconSize, isTemplate: isMonochrome) {
                icons.append(copy)
            }
            if let codexBrand = createProviderBrandIcon(.codex, isMonochrome: isMonochrome, size: providerBrandIconSize) {
                icons.append(codexBrand)
            }

        case .percentageOnly, .both:
            // Claude 部分：5h/7d 走账户组合图标（环+饼形扇区），其余类型（Opus/Sonnet/Extra）走原有 `createIconForType`
            var claudeIcons = createAccountGlyphIcons(from: claudeSnapshots, types: claudeTypes, button: button, isMonochrome: isMonochrome)
            let remainingClaudeTypes = claudeTypes.filter { $0 != .fiveHour && $0 != .sevenDay }
            claudeIcons.append(contentsOf: remainingClaudeTypes.compactMap { createIconForType($0, data: data, isMonochrome: isMonochrome, button: button) })
            if !claudeIcons.isEmpty {
                if settings.iconDisplayMode == .both {
                    let iconName = isMonochrome ? "AppIconReverse" : "AppIcon"
                    if let copy = ImageHelper.createSquareIcon(named: iconName, size: providerBrandIconSize, isTemplate: isMonochrome) {
                        icons.append(copy)
                    }
                }
                icons.append(contentsOf: claudeIcons)
            }

            // Codex 部分
            let codexIcons = buildCodexIcons(codex: codex, types: codexTypes, isMonochrome: isMonochrome, button: button)
            if !codexIcons.isEmpty {
                if settings.iconDisplayMode == .percentageOnly, !claudeIcons.isEmpty {
                    icons.append(createMenuBarDividerIcon(isMonochrome: isMonochrome))
                } else if settings.iconDisplayMode == .both,
                   let brand = createProviderBrandIcon(.codex, isMonochrome: isMonochrome, size: providerBrandIconSize) {
                    icons.append(brand)
                }
                icons.append(contentsOf: codexIcons)
            }

        case .none:
            // 不显示图标：仅显示轻量分隔线，保留可点击的状态栏锚点
            icons.append(createMenuBarDividerIcon(isMonochrome: isMonochrome))
        }

        let combined = icons.isEmpty ? createSimpleCircleIcon() : combineIcons(icons, spacing: 2.0, height: metricIconSize)
        combined.isTemplate = isMonochrome
        return combined
    }

    /// Codex-only 模式图标（无 Claude 账号时）
    private func createCodexOnlyIcon(
        codex: CodexUsageData,
        codexTypes: [LimitType],
        isMonochrome: Bool,
        button: NSStatusBarButton?
    ) -> NSImage {
        switch settings.iconDisplayMode {
        case .none:
            return createMenuBarDividerIcon(isMonochrome: isMonochrome)

        case .iconOnly:
            return createProviderBrandIcon(.codex, isMonochrome: isMonochrome, size: providerBrandIconSize) ?? createSimpleCircleIcon()

        case .percentageOnly, .both:
            var icons: [NSImage] = []
            if settings.iconDisplayMode == .both,
               let brand = createProviderBrandIcon(.codex, isMonochrome: isMonochrome, size: providerBrandIconSize) {
                icons.append(brand)
            }
            icons.append(contentsOf: buildCodexIcons(codex: codex, types: codexTypes, isMonochrome: isMonochrome, button: button))
            if icons.isEmpty { return createSimpleCircleIcon() }
            let combined = icons.count == 1 ? icons[0] : combineIcons(icons, spacing: 3.0, height: metricIconSize)
            combined.isTemplate = isMonochrome
            return combined
        }
    }

    /// 构建 Codex 指标图标列表
    private func buildCodexIcons(codex: CodexUsageData, types: [LimitType], isMonochrome: Bool, button: NSStatusBarButton?) -> [NSImage] {
        let showPlaceholder = settings.displayMode == .custom
        return types.compactMap { type -> NSImage? in
            switch type {
            case .codexPrimary:
                let percentage = codex.primary?.percentage ?? (showPlaceholder ? 0 : nil)
                return percentage.flatMap { createCodexIcon(type: type, percentage: $0, isMonochrome: isMonochrome, button: button) }
            case .codexSecondary:
                let percentage = codex.secondary?.percentage ?? (showPlaceholder ? 0 : nil)
                return percentage.flatMap { createCodexIcon(type: type, percentage: $0, isMonochrome: isMonochrome, button: button) }
            case .codexExtraUsage:
                let percentage: Double?
                if let extra = codex.extraUsage, extra.enabled {
                    percentage = extra.percentage
                } else if showPlaceholder {
                    percentage = 0
                } else {
                    percentage = nil
                }
                return percentage.flatMap { createCodexIcon(type: type, percentage: $0, isMonochrome: isMonochrome, button: button) }
            default:
                return nil
            }
        }
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
        }
    }

    /// 创建仅百分比的组合图标
    private func createCombinedPercentageIcon(
        data: UsageData,
        types: [LimitType],
        claudeSnapshots: [AccountUsageSnapshot],
        isMonochrome: Bool,
        button: NSStatusBarButton?
    ) -> NSImage {
        // 5h/7d 走账户组合图标（环+饼形扇区），其余类型（Opus/Sonnet/Extra）走原有 `createIconForType`
        var icons = createAccountGlyphIcons(from: claudeSnapshots, types: types, button: button, isMonochrome: isMonochrome)
        let remainingTypes = types.filter { $0 != .fiveHour && $0 != .sevenDay }
        icons.append(contentsOf: remainingTypes.compactMap { type in
            createIconForType(type, data: data, isMonochrome: isMonochrome, button: button)
        })

        // 组合图标
        if icons.isEmpty {
            return createSimpleCircleIcon()
        } else if icons.count == 1 {
            return icons[0]
        } else {
            let combined = combineIcons(icons, spacing: 3.0, height: 18)
            combined.isTemplate = isMonochrome
            return combined
        }
    }

    /// 创建 App 图标 + 百分比的组合图标
    private func createCombinedIconWithAppIcon(
        data: UsageData,
        types: [LimitType],
        claudeSnapshots: [AccountUsageSnapshot],
        isMonochrome: Bool,
        button: NSStatusBarButton?
    ) -> NSImage {
        // 获取 App 图标（单色模式使用反转图标）
        let iconName = isMonochrome ? "AppIconReverse" : "AppIcon"
        guard let appIconCopy = ImageHelper.createSquareIcon(named: iconName, size: providerBrandIconSize, isTemplate: isMonochrome) else {
            return createCombinedPercentageIcon(data: data, types: types, claudeSnapshots: claudeSnapshots, isMonochrome: isMonochrome, button: button)
        }

        // 5h/7d 走账户组合图标（环+饼形扇区），其余类型（Opus/Sonnet/Extra）走原有 `createIconForType`
        var percentageIcons = createAccountGlyphIcons(from: claudeSnapshots, types: types, button: button, isMonochrome: isMonochrome)
        let remainingTypes = types.filter { $0 != .fiveHour && $0 != .sevenDay }
        percentageIcons.append(contentsOf: remainingTypes.compactMap { type in
            createIconForType(type, data: data, isMonochrome: isMonochrome, button: button)
        })

        // 组合 App 图标 + 百分比图标
        var allIcons = [appIconCopy]
        allIcons.append(contentsOf: percentageIcons)

        let combined = combineIcons(allIcons, spacing: 3.0, height: metricIconSize)
        combined.isTemplate = isMonochrome
        return combined
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

    // MARK: - Shared Ring / Wedge Drawing Helpers (P05)

    /// 提取自 `createCircleImage`/`createCircleTemplateImage` 的外圈弧线描边逻辑：
    /// 保留原有的圆头端点角度修正数学（cap-angle correction），供彩色/单色圆环
    /// 以及新的账户组合图标（`createAccountGlyph`）共用，避免重复实现。
    /// - Parameters:
    ///   - rect: 图标绘制区域（正方形），圆心与半径均从此推导
    ///   - percentage: 使用百分比 (0-100+)
    ///   - color: 描边颜色
    ///   - lineWidth: 描边宽度
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
    ///   - rect: 扇区绘制区域，半径小于外圈进度环，以在环与扇区之间留出可视间隙
    ///   - percentage: 使用百分比 (0-100+)；0% 时不绘制任何图形（无残留细线）
    ///   - color: 填充颜色
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

    /// 在外观（浅色/深色菜单栏）间应用亮度自适应：仅提取 `NSColor.adjustedForDarkMode()`
    /// 这部分与百分比无关的亮度变换逻辑复用，而非百分比驱动的颜色选择（`UsageColorScheme.*ColorAdaptive`），
    /// 使其可以作用于任意账户自定义颜色（`Account.color`），不仅限于原有的危险色阶。
    private func appearanceAdaptiveColor(_ base: NSColor, appearance: NSAppearance) -> NSColor {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? base.adjustedForDarkMode() : base
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
    /// 而不是几乎不可见的一个小点（P05 code review finding #5）。
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
    /// 绘制并将 `image.isTemplate = true`（P05 code review finding #3），以便随菜单栏浅色/深色/
    /// 高亮状态反色；由于单色模式下无法再靠账户颜色区分身份，第二个账户的轨道圆环改用虚线
    /// （`useDashedTrack`，复用既有的虚线区分约定）。
    /// `showFiveHour`/`showSevenDay` 反映用户在设置中实际勾选展示的类型（finding #1）：
    /// 未勾选的窗口不绘制对应图形；若该账户在两个已勾选窗口上均无数据，返回占位图标兜底
    /// （理论上不应被 `createAccountGlyphIcons` 的前置过滤选中，这里仅作防御）。
    /// - Parameters:
    ///   - snapshot: 账户用量快照
    ///   - isNearLimit: 是否已临近上限（决定是否叠加警示描边）
    ///   - appearance: 状态栏按钮的外观，用于亮度自适应
    ///   - showFiveHour: 用户是否勾选展示 5h 窗口
    ///   - showSevenDay: 用户是否勾选展示 7d 窗口
    ///   - isMonochrome: 是否为单色模式
    ///   - useDashedTrack: 单色模式下是否使用虚线轨道以区分账户（通常仅第二个账户为 true）
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

        let rect = NSRect(origin: .zero, size: size)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let color: NSColor
        if isMonochrome {
            color = NSColor.labelColor
        } else {
            color = appearanceAdaptiveColor(NSColor(snapshot.color.swiftUIColor), appearance: appearance)
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

        image.unlockFocus()
        image.isTemplate = isMonochrome
        return image
    }

    /// 按 provider 选出最紧迫的账户（`topUrgentAccounts`，上限 2 个），并映射为组合图标数组。
    /// - `types` 是用户当前实际勾选展示的类型（自定义模式下可能仅勾选 5h 或仅勾选 7d，
    ///   甚至两者都未勾选）：两者都未勾选时直接返回空数组，不为该账户组渲染任何图形
    ///   （P05 code review finding #1）。
    /// - 先按「在已勾选窗口上是否有真实数据」过滤快照（finding #6），确保两个窗口均无数据
    ///   （拉取失败/尚未加载）的账户不会因为可用账户不足 `limit` 而占据一个图标槽位、
    ///   渲染出无意义的占位圆；`createAccountGlyph` 内部的防御性 guard 仍保留作为兜底，
    ///   但不再作为主要过滤手段。
    private func createAccountGlyphIcons(
        from snapshots: [AccountUsageSnapshot],
        types: [LimitType],
        button: NSStatusBarButton?,
        isMonochrome: Bool
    ) -> [NSImage] {
        guard !snapshots.isEmpty else { return [] }

        let showFiveHour = types.contains(.fiveHour)
        let showSevenDay = types.contains(.sevenDay)
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
    ///   - icons: 要组合的图标数组
    ///   - spacing: 图标间距
    ///   - height: 统一高度（默认18）
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
    ///   - type: 限制类型
    ///   - data: 用量数据
    ///   - isMonochrome: 是否为单色模式
    ///   - button: 状态栏按钮
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
            // P05: Claude 的 5h/7d 圆形指标已被账户组合图标（`createAccountGlyph`，
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
            // Codex 数据在 Phase 4 通过 createCodexIcon 独立渲染
            // createIconForType 仅处理 Claude UsageData，此处返回 nil
            return nil
        }
    }

    /// 根据 Codex 用量数据创建单个图标（Codex 专用，Phase 4 接入 UI）
    func createCodexIcon(
        type: LimitType,
        percentage: Double,
        isMonochrome: Bool,
        button: NSStatusBarButton?
    ) -> NSImage? {
        let removeBackground = settings.iconStyleMode == .colorTranslucent

        switch type {
        case .codexPrimary:
            if isMonochrome {
                return createCircleTemplateImage(percentage: percentage, size: NSSize(width: 18, height: 18), button: button, removeBackground: true)
            }
            let color = UsageColorScheme.codexPrimaryColorAdaptive(percentage, for: button)
            return createCircleImage(percentage: percentage, size: NSSize(width: 18, height: 18), colorOverride: color, button: button, removeBackground: removeBackground)

        case .codexSecondary:
            if isMonochrome {
                return createCircleTemplateImage(percentage: percentage, size: NSSize(width: 18, height: 18), useSevenDayStyle: true, button: button, removeBackground: true)
            }
            let color = UsageColorScheme.codexSecondaryColorAdaptive(percentage, for: button)
            return createCircleImage(percentage: percentage, size: NSSize(width: 18, height: 18), colorOverride: color, useDashedStyle: true, button: button, removeBackground: removeBackground)

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
