//
//  UsageDetailView+Helpers.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2025-12-18.
//  Copyright © 2025 f-is-h. All rights reserved.
//

import SwiftUI

// MARK: - Helper Methods Extension

extension UsageDetailView {

    // MARK: - Animation Methods

    /// 启动旋转动画
    func startRotationAnimation() {
        // 清除旧的定时器
        stopRotationAnimation()

        // 重置角度
        rotationAngle = 0

        // 创建新的定时器，每 0.016 秒更新一次（约 60fps）
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            withAnimation(.linear(duration: 0.016)) {
                rotationAngle += 6  // 每帧旋转 6 度，1秒完成一圈
                if rotationAngle >= 360 {
                    rotationAngle -= 360
                }
            }
        }
    }

    /// 停止旋转动画
    func stopRotationAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        withAnimation(.default) {
            rotationAngle = 0
        }
    }

    // MARK: - Graph View Selection

    /// 单列弹出窗口的图表区域：同一张图同时承载 Claude + Codex 的点，`usageData` 可以为 nil
    /// （Codex-only 用户），`LinearUsageGraphView` 本身会渲染 loading/占位状态。
    /// 点击图表触发的刷新动作，按**已配置了哪些 Provider**决定，而不是按「哪边碰巧已经有数据」。
    /// - 只有 Claude：`.refreshClaude`（`refreshingProvider = .claude`，只转 Claude 那半边的动画）。
    /// - 只有 Codex：`.refreshCodex`。按数据判断的话，Codex-only 用户在首次响应到达之前
    ///   点图会落到 `.refreshClaude`，而 `handleClaudeOnlyRefresh` 开头的
    ///   `guard shouldFetchClaudeUsage` 直接返回 —— 点了完全没反应。
    /// - 两边都有、或两边都没有（DEBUG 模拟数据）：`.refresh` 走全量。
    /// - Note: 三者共用 `DataRefreshManager.lastManualRefreshTime` 这一个 10 秒防抖时间戳，
    ///   不存在各自独立的防抖计数。
    private var graphTapRefreshAction: MenuAction {
        let settings = UserSettings.shared
        let hasClaude = settings.hasValidCredentials
        let hasCodex = settings.hasValidCodexCredentials
        if hasClaude && !hasCodex { return .refreshClaude }
        if hasCodex && !hasClaude { return .refreshCodex }
        return .refresh
    }

    @ViewBuilder
    func usageGraphArea() -> some View {
        LinearUsageGraphView(
            usageData: usageData,
            codexUsageData: codexUsageData,
            activeDisplayTypes: UserSettings.shared.getActiveDisplayTypes(
                usageData: usageData,
                codexUsageData: codexUsageData
            ),
            isRefreshing: refreshState.isRefreshing,
            claudeSnapshots: claudeSnapshots
        )
        .frame(height: 114)
        .contentShape(Rectangle())
        .onTapGesture {
            if refreshState.canRefresh && !refreshState.isRefreshing {
                onMenuAction?(graphTapRefreshAction)
            }
        }
    }

    // MARK: - Text Helper Methods

    /// 创建彩虹文字
    /// - Parameter text: 要显示的文本
    /// - Returns: 带彩虹效果的文本视图
    @ViewBuilder
    func rainbowText(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(
                LinearGradient(
                    colors: [.red, .orange, .yellow, .green, .blue, .purple, .red],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }

    /// 创建菜单更新文本（部分文字带颜色）
    /// - Returns: 带颜色的AttributedString
    func createUpdateMenuText() -> AttributedString {
        let baseText = L.Menu.checkUpdates
        let badgeText = L.Update.Notification.badgeShort
        let fullText = baseText + "   " + badgeText

        var attributedString = AttributedString(fullText)

        // 找到徽章文本的范围并设置颜色
        if let range = attributedString.range(of: badgeText) {
            attributedString[range].foregroundColor = .orange
        }

        return attributedString
    }
}
