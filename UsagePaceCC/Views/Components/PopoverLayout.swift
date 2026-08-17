//
//  PopoverLayout.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-08-17.
//  Copyright © 2025 f-is-h. All rights reserved.
//

import Foundation

/// 弹出窗口尺寸的单一计算来源（P06：单列折叠）。
/// 之前这套 `base 190 / row 26 / spacing 5` 公式在 `UsageDetailView` 里重复了三次，
/// 在 `MenuBarManager.usageDetailContentSize()` 里重复了第四次；SwiftUI 的 frame
/// 与 `NSPopover` 的 content size 必须逐像素一致，任何一处公式漂移都会导致裁剪或空白。
/// 两处调用方都改为委托给这里。
enum PopoverLayout {
    /// 弹出窗口固定宽度（D3′：双列 580pt 路径已删除，宽度恒为单列宽度）。
    static let width: CGFloat = 290

    private static let baseHeight: CGFloat = 190
    private static let rowHeight: CGFloat = 26
    private static let rowSpacing: CGFloat = 5

    /// 根据实际渲染的行数计算内容高度。
    static func height(rowCount: Int) -> CGFloat {
        let rows = CGFloat(rowCount) * rowHeight + CGFloat(max(0, rowCount - 1)) * rowSpacing
        return baseHeight + rows
    }

    /// 单列弹出窗口 legend 区域要渲染的类型列表。
    ///
    /// - Important: 这是**视图和高度计算共用的唯一来源**。`UsageDetailView.legendSection`
    ///   按这个列表渲染，`rowCount` 按同一个列表计数；两边各算各的就会出现「布局留了 3 行、
    ///   视图只画 2 行」这种永久空白。改这里之前先确认两边都还对得上。
    ///
    /// - Circular 模式下 Codex 完全不出现（D5′）——不论圆环还是 legend 行。
    /// - Linear 模式下 Claude 行与 Codex 行在同一列纵向堆叠（不再是并排双列取 max，而是相加）。
    /// - `codexErrorMessage` 非 nil 时，Codex 的 legend 行整体被 `codexErrorRow` 顶替。
    /// - 数据为 nil 的 Provider 一行都不出：`.custom` 模式下 `getActiveDisplayTypes` 无视
    ///   数据是否存在都会返回用户勾选的类型，照单全收会让还在转菊花的弹窗按满高打开。
    static func legendTypes(
        usageData: UsageData?,
        codexUsageData: CodexUsageData?,
        codexErrorMessage: String?,
        graphDisplayType: GraphDisplayType
    ) -> [LimitType] {
        let combined = UserSettings.shared.getActiveDisplayTypes(
            usageData: usageData,
            codexUsageData: codexUsageData
        )
        let claudeTypes = usageData == nil ? [] : combined.filter { $0.provider == .claude }

        switch graphDisplayType {
        case .circular:
            return claudeTypes
        case .linear:
            guard codexErrorMessage == nil, codexUsageData != nil else { return claudeTypes }
            return claudeTypes + combined.filter { $0.provider == .codex }
        }
    }

    /// 计算单列弹出窗口中实际渲染的行数（legend 行 + Codex 错误行，二者互斥）。
    ///
    /// 行数规则与 `UsageDetailView.legendSection` 一一对应：
    /// - 只有一个类型且属于 Claude：渲染两行 InfoRow（沿用改动前的行为），按 2 计。
    /// - 只有一个类型且属于 Codex：渲染一行 `UnifiedLimitRow`，按 1 计（Codex 不做双行特例）。
    /// - 其余情况：行数 = 类型数。
    /// - `codexErrorRow` 固定占一行——这样 CLI token 每 ~10 天过期一次时，弹出窗口不会因为
    ///   「有数据 → 报错」的切换而跳动或改变高度。
    static func rowCount(
        usageData: UsageData?,
        codexUsageData: CodexUsageData?,
        codexErrorMessage: String?,
        graphDisplayType: GraphDisplayType
    ) -> Int {
        let types = legendTypes(
            usageData: usageData,
            codexUsageData: codexUsageData,
            codexErrorMessage: codexErrorMessage,
            graphDisplayType: graphDisplayType
        )

        var rows: Int
        if types.count == 1 {
            rows = types[0].provider == .claude ? 2 : 1
        } else {
            rows = types.count
        }

        if graphDisplayType == .linear, codexErrorMessage != nil {
            rows += 1
        }

        return rows
    }
}
