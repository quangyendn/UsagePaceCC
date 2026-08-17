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

    /// 计算单列弹出窗口中实际渲染的行数（legend 行 + Codex 错误行，二者互斥）。
    ///
    /// - Circular 模式下，Codex 完全不出现（D5′）——不论是圆环还是 legend 行，
    ///   因此行数只取决于 Claude。
    /// - Linear 模式下，Claude 行与 Codex 行在同一列里纵向堆叠（不再是并排双列取 max，
    ///   而是相加），所以行数 = Claude 行数 + Codex 行数。
    /// - 当 `codexErrorMessage` 非 nil 时，`codexErrorRow` 会顶替 Codex 的 legend 行，
    ///   且固定只占一行——这样 CLI token 每 ~10 天过期一次时，弹出窗口不会因为
    ///   「有数据 → 报错」的切换而跳动或改变高度。
    static func rowCount(
        usageData: UsageData?,
        codexUsageData: CodexUsageData?,
        codexErrorMessage: String?,
        graphDisplayType: GraphDisplayType
    ) -> Int {
        let claudeTypes = UserSettings.shared.getActiveDisplayTypes(usageData: usageData)
            .filter { $0.provider == .claude }
        // 单一类型时，Claude 侧用两行 InfoRow 展示（沿用既有行为），因此行数按 2 计。
        let claudeRowCount = claudeTypes.count == 1 ? 2 : claudeTypes.count

        guard graphDisplayType == .linear else {
            return claudeRowCount
        }

        let codexRowCount: Int
        if codexErrorMessage != nil {
            codexRowCount = 1
        } else if let codex = codexUsageData {
            codexRowCount = UserSettings.shared.getActiveDisplayTypes(usageData: nil, codexUsageData: codex)
                .filter { $0.provider == .codex }
                .count
        } else {
            codexRowCount = 0
        }

        return claudeRowCount + codexRowCount
    }
}
