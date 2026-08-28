//
//  UsageDetailView.swift
//  UsagePaceCC
//
//  Created by f-is-h on 2025-10-15.
//  Copyright © 2025 f-is-h. All rights reserved.
//

import SwiftUI

/// 用量详情视图
/// 显示 Claude 的当前使用情况，包括百分比进度条、倒计时和重置时间
struct UsageDetailView: View {
    @Binding var usageData: UsageData?
    @Binding var codexUsageData: CodexUsageData?
    @Binding var errorMessage: String?
    @Binding var codexErrorMessage: String?
    @ObservedObject var refreshState: RefreshState
    /// 菜单操作回调
    var onMenuAction: ((MenuAction) -> Void)? = nil
    @StateObject private var localization = LocalizationManager.shared
    /// 是否有可用更新（用于显示文字和徽章）
    @Binding var hasAvailableUpdate: Bool
    /// 是否应显示更新徽章（用户未确认时才显示徽章）
    @Binding var shouldShowUpdateBadge: Bool
    /// 所有已保存的 Claude 账户快照（P03）。驱动 Linear 模式下新的账户驱动图表点/图例行。
    /// 与 usageData/codexUsageData/errorMessage 一样是 @Binding（code-review fix 1）：popover
    /// 打开时是同步构造的，异步刷新落地后必须能通过这个 binding 反映到已打开的 popover 里，
    /// 而不是构造时的一次性快照——否则整个 popover 打开期间 5h/7d 内容永远空白/过期。
    @Binding var claudeSnapshots: [AccountUsageSnapshot]

    /// 菜单操作类型
    enum MenuAction {
        case generalSettings
        case authSettings
        case checkForUpdates
        case about
        case webUsage
        case quit
        case refresh
        case refreshClaude
        case refreshCodex
    }
    
    // 用于动画的状态（改为从外部传入，避免每次重建视图时重置）
    @State var rotationAngle: Double = 0
    @State var animationTimer: Timer?
    // 显示更新通知
    @State private var showUpdateNotification = false
    // 显示模式切换（false: 重置时间, true: 剩余时间）
    @AppStorage("showRemainingMode") private var savedRemainingMode = false
    @State private var showRemainingMode = false
    
    // MARK: - Body

    private var isClaudeRefreshing: Bool {
        refreshState.isRefreshingProvider(.claude)
    }

    /// 头部展示的 Provider：Claude 数据存在或 Claude 凭据有效时用 Claude 品牌，
    /// 否则（Codex-only）用 Codex 品牌。
    private var primaryProvider: ProviderType {
        (usageData != nil || UserSettings.shared.hasValidCredentials) ? .claude : .codex
    }

    /// 新的账户驱动图例行：`claudeSnapshots` 的 5h/7d 行
    /// + Codex 单账户包装出的 primary 行。
    private var legendItems: [LegendRowItem] {
        PopoverLayout.legendItems(
            claudeSnapshots: claudeSnapshots,
            codexUsageData: codexUsageData,
            codexAccount: UserSettings.shared.currentCodexAccount,
            activeDisplayTypes: UserSettings.shared.getActiveDisplayTypes(
                usageData: usageData,
                codexUsageData: codexUsageData
            )
        )
    }

    /// Linear 模式下仍走旧路径的类型（opus/sonnet/extra/codexSecondary/codexExtraUsage）——
    /// `legendItems` 已经覆盖的 5h/7d/codexPrimary 被过滤掉，避免重复渲染。
    private var linearLegacyTypes: [LimitType] {
        PopoverLayout.linearLegacyTypes(
            usageData: usageData,
            codexUsageData: codexUsageData,
            codexErrorMessage: codexErrorMessage
        )
    }

    /// 实际渲染的行数是 `legendItems.count + linearLegacyTypes.count`
    /// （同 `PopoverLayout.rowCount`），行间距据此调整。
    private var contentSpacing: CGFloat {
        let rowCount = legendItems.count + linearLegacyTypes.count
        return rowCount >= 2 ? 10 : 16
    }

    private var contentWidth: CGFloat {
        PopoverLayout.width
    }

    private var contentHeight: CGFloat {
        let rowCount = PopoverLayout.rowCount(
            usageData: usageData,
            codexUsageData: codexUsageData,
            codexErrorMessage: codexErrorMessage,
            claudeSnapshots: claudeSnapshots,
            codexAccount: UserSettings.shared.currentCodexAccount
        )
        return PopoverLayout.height(rowCount: rowCount)
    }

    @ViewBuilder
    private func claudeErrorView(_ error: String) -> some View {
        // 错误信息（Claude 的错误路径是整页替换：没有 Claude 数据时没有别的东西可显示）
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text(error)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            // 操作按钮组
            HStack(spacing: 12) {
                // 如果是认证信息错误，显示设置按钮
                if error.contains("认证") || error.contains("配置") || error.contains("Authentication") || error.contains("configured") {
                    Button(action: {
                        onMenuAction?(.authSettings)
                    }) {
                        Label(L.Usage.goToSettings, systemImage: "key.fill")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }

                // 诊断连接按钮（所有错误都显示）
                Button(action: {
                    onMenuAction?(.authSettings)
                }) {
                    Label(L.Usage.runDiagnostic, systemImage: "stethoscope")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
    }

    /// Codex 的紧凑错误行（P06 新增）：`codexOnlyMainContent` 曾是 `codexErrorMessage`
    /// 唯一的渲染出口，删除它之后必须在这里补上——CLI token 大约每 10 天过期一次，
    /// 这是常规路径，不是边角情况。占据一个 legend 行的位置，点按跳转到 Auth 设置。
    @ViewBuilder
    private var codexErrorRow: some View {
        if let error = codexErrorMessage {
            Button(action: {
                onMenuAction?(.authSettings)
            }) {
                HStack(spacing: 8) {
                    if let icon = ImageHelper.createCodexIcon(size: 16) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                    }

                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 12)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
        }
    }

    /// legend 区域：账户驱动渲染（`legendItems`）+ 仍留在旧路径上的类型（`linearLegacyTypes`）。
    @ViewBuilder
    private var legendSection: some View {
        linearLegendSection
    }

    /// 账户驱动的 5h/7d/codexPrimary 行（新格式，见
    /// `UnifiedLimitRow.init(accountItem:showRemainingMode:)`）+ 仍留在旧路径上的类型
    /// （opus/sonnet/extra/codexSecondary/codexExtraUsage，渲染方式完全不变）。
    /// 两个 ForEach 加起来的行数必须与 `PopoverLayout.rowCount`（Linear 分支）逐行对应，
    /// 否则会出现空白或裁剪（Locked Constraint 2）。
    @ViewBuilder
    private var linearLegendSection: some View {
        VStack(spacing: 5) {
            ForEach(legendItems) { item in
                UnifiedLimitRow(accountItem: item, showRemainingMode: showRemainingMode)
            }
            ForEach(linearLegacyTypes, id: \.self) { type in
                if type.provider == .claude {
                    UnifiedLimitRow(type: type, data: usageData, showRemainingMode: showRemainingMode)
                } else {
                    UnifiedLimitRow(type: type, codexData: codexUsageData, showRemainingMode: showRemainingMode)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { showRemainingMode.toggle() }
            savedRemainingMode = showRemainingMode
        }
        .padding(.horizontal, 14)
    }

    /// 单列主体内容：Claude 报错时整页替换（不变）；只要任一 Provider 有数据或报错
    /// 就展示 图 + legend + Codex 错误行；两边都还没有任何数据/错误时展示通用 loading。
    @ViewBuilder
    private var mainContent: some View {
        if let error = errorMessage {
            claudeErrorView(error)
        } else if usageData != nil || codexUsageData != nil || codexErrorMessage != nil {
            VStack(spacing: 15) {
                usageGraphArea()
                legendSection
                codexErrorRow
            }
        } else {
            // 加载中
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.2)
                Text(L.Usage.loading)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(height: 100)
        }
    }

    // MARK: - Header Buttons

    /// 刷新按钮 + 三点菜单按钮（共用于单列和双列头部）
    @ViewBuilder
    private var refreshAndMenuButtons: some View {
        Button(action: { onMenuAction?(.refresh) }) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .opacity(refreshState.canRefresh ? 1.0 : 0.3)
                .rotationEffect(.degrees(refreshState.isRefreshing ? rotationAngle : 0))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .disabled(!refreshState.canRefresh || refreshState.isRefreshing)
        .focusable(false)

        ZStack(alignment: .topTrailing) {
            Menu {
                if UserSettings.shared.accounts.count > 1 {
                    Menu {
                        ForEach(UserSettings.shared.accounts) { account in
                            Button(action: { UserSettings.shared.switchToAccount(account) }) {
                                HStack {
                                    Text(account.displayName)
                                    if account.id == UserSettings.shared.currentAccountId {
                                        Spacer(); Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        let name = UserSettings.shared.currentAccountName ?? L.Menu.account
                        Label("\(L.Menu.accountPrefix) \(name)", systemImage: "person.2")
                    }
                    Divider()
                }

                if UserSettings.shared.codexAccounts.count > 1 {
                    Menu {
                        ForEach(UserSettings.shared.codexAccounts) { account in
                            Button(action: { UserSettings.shared.switchToCodexAccount(account) }) {
                                HStack {
                                    Text(account.displayName)
                                    if account.id == UserSettings.shared.currentCodexAccountId {
                                        Spacer(); Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        let name = UserSettings.shared.currentCodexAccount?.displayName ?? "Codex"
                        Label("Codex: \(name)", systemImage: "person.2.fill")
                    }
                    Divider()
                }

                Button(action: { onMenuAction?(.generalSettings) }) {
                    Label(L.Menu.generalSettings, systemImage: "gearshape")
                }
                Button(action: { onMenuAction?(.authSettings) }) {
                    Label(L.Menu.authSettings, systemImage: "key")
                }
                if hasAvailableUpdate {
                    Button(action: { onMenuAction?(.checkForUpdates) }) {
                        Label { Text(createUpdateMenuText()) } icon: {
                            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        }
                    }
                } else {
                    Button(action: { onMenuAction?(.checkForUpdates) }) {
                        Label(L.Menu.checkUpdates, systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                Button(action: { onMenuAction?(.about) }) {
                    Label(L.Menu.about, systemImage: "info.circle")
                }
                Divider()
                Button(action: { onMenuAction?(.webUsage) }) {
                    Label(L.Menu.webUsage, systemImage: "safari")
                }
                Divider()
                Button(action: { onMenuAction?(.quit) }) {
                    Label(L.Menu.quit, systemImage: "power")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(90))
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonStyle(.plain)
            .focusable(false)

            if shouldShowUpdateBadge {
                Circle().fill(Color.red).frame(width: 6, height: 6).offset(x: 5, y: -5)
            }
        }
    }

    @ViewBuilder
    private func headerView(provider: ProviderType, showsControls: Bool) -> some View {
        let headerIconSize: CGFloat = 18
        let headerRowHeight: CGFloat = 20
        HStack {
            if provider == .claude {
                if let icon = ImageHelper.createAppIcon(size: headerIconSize) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: headerIconSize, height: headerIconSize)
                } else {
                    Image(systemName: "chart.pie.fill")
                        .foregroundColor(.blue)
                }
            } else if let icon = ImageHelper.createCodexIcon(size: headerIconSize) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: headerIconSize, height: headerIconSize)
            }

            Text(provider == .claude ? L.Usage.title : L.Usage.codexTitle)
                .font(.headline)

            Spacer()

            if showsControls {
                refreshAndMenuButtons
            }
        }
        .frame(height: headerRowHeight, alignment: .center)
        .padding(.horizontal)
        .padding(.top)
    }

    @ViewBuilder
    private var updateNotificationView: some View {
        if showUpdateNotification {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.red, .orange, .yellow, .green, .blue, .purple, .red],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                rainbowText(L.Update.Notification.available)
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 12)
            .padding(.top, -8)
            .padding(.bottom, 6)
            .transition(.opacity.combined(with: .scale))
        }
    }

    private var singleColumnBody: some View {
        VStack(spacing: contentSpacing) {
            VStack(spacing: contentSpacing) {
                headerView(provider: primaryProvider, showsControls: true)
                mainContent
            }

            updateNotificationView
            Spacer()
        }
    }

    var body: some View {
        singleColumnBody
        .frame(width: contentWidth, height: contentHeight)
        .id(localization.updateTrigger)  // 语言变化时重新创建视图
        .onAppear {
            showRemainingMode = savedRemainingMode
            // 如果打开时已经在刷新，启动旋转动画
            if refreshState.isRefreshing {
                startRotationAnimation()
            }
            // 如果有更新通知消息，显示通知
            if refreshState.notificationMessage != nil {
                withAnimation {
                    showUpdateNotification = true
                }
                // 3秒后隐藏通知
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation {
                        showUpdateNotification = false
                    }
                }
            }
        }
        .onChange(of: refreshState.isRefreshing) { newValue in
            if newValue { startRotationAnimation() } else { stopRotationAnimation() }
        }
        .onChange(of: refreshState.notificationMessage) { message in
            // 监听通知消息变化
            if message != nil {
                withAnimation {
                    showUpdateNotification = true
                }
                // 3秒后隐藏通知
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation {
                        showUpdateNotification = false
                    }
                }
            } else {
                withAnimation {
                    showUpdateNotification = false
                }
            }
        }
        .onDisappear {
            // 视图消失时清理定时器
            stopRotationAnimation()
        }
        #if DEBUG
        .background(
            UserSettings.shared.debugKeepDetailWindowOpen ? Color.white : Color.clear
        )
        #endif
    }
}

// 预览
struct UsageDetailView_Previews: PreviewProvider {
    @State static var sampleData: UsageData? = UsageData(
        fiveHour: UsageData.LimitData(
            percentage: 45,
            resetsAt: Date().addingTimeInterval(3600 * 2.5)
        ),
        sevenDay: nil,
        opus: nil,
        sonnet: nil,
        extraUsage: nil
    )

    @State static var errorMsg: String? = nil
    @State static var codexErrorMsg: String? = nil
    @State static var codexData: CodexUsageData? = nil
    @StateObject static var refreshState = RefreshState()
    @State static var hasUpdate = false
    @State static var shouldShowBadge = false
    @State static var snapshots: [AccountUsageSnapshot] = []

    static var previews: some View {
        UsageDetailView(
            usageData: $sampleData,
            codexUsageData: $codexData,
            errorMessage: $errorMsg,
            codexErrorMessage: $codexErrorMsg,
            refreshState: refreshState,
            hasAvailableUpdate: $hasUpdate,
            shouldShowUpdateBadge: $shouldShowBadge,
            claudeSnapshots: $snapshots
        )
    }
}
