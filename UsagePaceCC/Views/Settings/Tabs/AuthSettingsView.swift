//
//  AuthSettingsView.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2025-12-02.
//  Copyright © 2025 f-is-h. All rights reserved.
//

import OSLog
import SwiftUI

/// 认证设置页面
/// 使用卡片式布局，用于管理多账户
struct AuthSettingsView: View {
    @ObservedObject private var settings = UserSettings.shared
    @State private var isAddingAccount = false
    @State private var newSessionKey = ""
    @State private var newAlias = ""
    @State private var isValidating = false
    @State private var validationError: String?
    @State private var isShowingPassword = false
    @State private var showDeleteConfirmation = false
    @State private var accountToDelete: Account?
    @State private var successMessage: String?
    @State private var showDeleteCodexConfirmation = false
    @State private var codexAccountToDelete: Account?
    @State private var showDeleteAntigravityConfirmation = false
    @State private var antigravityAccountToDelete: Account?
    /// Connect/Reconnect 期间的加载态：这两个按钮现在直接调用
    /// `AntigravityTokenProvider.shared.connectKeychain(_:)` 并拿到它的 completion，不再像修复前
    /// 那样要靠"已启用但既无数据也无错误"这个状态窗口去近似猜测。
    @State private var antigravityKeychainConnectTapped = false
    /// Enable 按钮的加载态，同 `antigravityKeychainConnectTapped`——`setAntigravityKeychainEnabled(true)`
    /// 内部会做一次探测（`AntigravityCredentialStore.isPresent`），虽然是同步调用，给两个按钮同样
    /// 的视觉反馈，而不是只有 Connect 有 spinner、Enable 没有。
    @State private var antigravityKeychainEnableTapped = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isAddingAccount {
                    // 添加账户视图
                    addAccountView
                } else {
                    // 多组织添加成功提示
                    if let message = successMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: { successMessage = nil }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .background(Color.blue.opacity(0.08))
                        .cornerRadius(8)
                    }

                    // 账户列表视图
                    accountListView

                    // 当前 Claude 账户详情
                    if let currentAccount = settings.currentAccount {
                        currentAccountDetailView(account: currentAccount)
                    }

                    // 当前 Codex 账户详情
                    if let currentCodexAccount = settings.currentCodexAccount {
                        currentCodexAccountDetailView(account: currentCodexAccount)
                    }

                    // Antigravity 区块：整节仅在 OAuth secrets 资源存在时渲染——`AntigravityOAuth.plist`
                    // 缺失时整节隐藏。clean clone / CI / 没跑过提取脚本的 fork 上，
                    // "Antigravity" 这个词不应出现在界面里。
                    if AntigravityOAuthSecrets.isConfigured {
                        antigravitySection
                    }

                    // 说明卡片
                    howToCard

                    // 诊断卡片
                    diagnosticsCard
                }
            }
            .padding()
        }
        // 打开 Auth 页时重新探测一次 CLI 凭据（只读，D10）。Re-scan 按钮长在 `sourceRow(.cli)` 里，
        // 而 opt-in 未完成时那一行根本不渲染；纯 Codex CLI 用户又没有任何 Claude 凭据，
        // `ensureRefreshingIfCredentialed()` 直接返回、定时器不启动，于是 `fetchUsage()` 里的
        // 周期性探测也不会跑 —— 不在这里探测的话，`codex login` 之后必须重启 App 才看得到 opt-in。
        .onAppear {
            settings.refreshCodexCLIState()
            // 同 `refreshCodexCLIState()` 的理由：没有这个探测，`antigravityKeychainDetected`
            // 只能等 `DataRefreshManager.fetchUsage()` 的下一个轮询周期才会翻转；而一个纯
            // Antigravity 用户若 `hasAnyValidCredentials` 没把 Antigravity 计入，定时器从未启动过，
            // 探测永远不会发生，Enable 行永远不出现。
            settings.refreshAntigravityKeychainState()
        }
        .alert(L.Account.deleteConfirmTitle, isPresented: $showDeleteConfirmation) {
            Button(L.Account.cancel, role: .cancel) {}
            Button(L.Account.delete, role: .destructive) {
                if let account = accountToDelete {
                    settings.removeAccount(account)
                }
            }
        } message: {
            Text(L.Account.deleteConfirmMessage)
        }
        .alert(L.Account.deleteConfirmTitle, isPresented: $showDeleteCodexConfirmation) {
            Button(L.Account.cancel, role: .cancel) {}
            Button(L.Account.delete, role: .destructive) {
                if let account = codexAccountToDelete {
                    settings.removeCodexAccount(account)
                }
            }
        } message: {
            Text(L.Account.deleteConfirmMessage)
        }
        // Claude/Codex 的账户删除在每次删除时都会二次确认（见上面两个 alert），Antigravity
        // 的 Sign out/Disable 与之保持一致——不是"只在最后一个账户时才确认"。
        .alert(L.Account.deleteConfirmTitle, isPresented: $showDeleteAntigravityConfirmation) {
            Button(L.Account.cancel, role: .cancel) {}
            Button(L.Account.delete, role: .destructive) {
                if let account = antigravityAccountToDelete {
                    signOutAntigravityAccount(account)
                }
            }
        } message: {
            Text(L.Account.deleteConfirmMessage)
        }
    }

    // MARK: - Account List View

    private var accountListView: some View {
        let hasCodex = settings.hasAnyCodexSource
        let hasBothProviders = !settings.accounts.isEmpty && hasCodex

        return SettingCard(
            icon: "person.2.fill",
            iconColor: .blue,
            title: L.Account.listTitle,
            hint: ""
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if settings.accounts.isEmpty && !settings.hasAnyCodexSource {
                    // 无账户时的提示
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text(L.Account.noAccounts)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    // Claude 账户组
                    if !settings.accounts.isEmpty {
                        if hasBothProviders {
                            providerSectionHeader(provider: .claude, label: L.Account.claudeAccounts)
                        }
                        ForEach(settings.accounts) { account in
                            accountRow(account: account, provider: .claude)
                        }
                    }

                    // Codex 账户组
                    if hasCodex {
                        if hasBothProviders {
                            providerSectionHeader(provider: .codex, label: L.Account.codexAccounts)
                                .padding(.top, 4)
                        }
                        ForEach(settings.codexAccounts) { account in
                            accountRow(account: account, provider: .codex)
                        }
                    }
                }

                // Codex 双来源选择区（D8'/D9）：仅当至少一个来源已配置、或用户曾显式启用过
                // CLI 时出现，保证纯 Claude 用户看到的 Auth 页与改动前完全一致（区块整体缺席，
                // 而非空区块）。
                // - Important: `codexCLIEnabled` 单独成一个条件。已 opt-in 但凭据文件暂时不在
                //   （`codex logout`、换机器、目录被删）时，前两个条件都是 false；若区块跟着消失，
                //   用户既看不到自己给过同意，也没有 Disable 按钮可以撤回。
                if settings.isCLISourceConfigured || settings.isBrowserSourceConfigured || settings.codexCLIEnabled {
                    codexSourceSection
                } else if settings.isCodexCLIOptInPending {
                    // 只检测到 CLI、用户还没启用：只多出一行 opt-in 提示，没有区块标题、
                    // 没有单选、没有账户分组 —— 没装 Codex CLI 的用户这里依然什么都看不到。
                    cliOptInRow
                }

                // 添加账户入口
                addAccountActionsView
            }
        }
    }

    // MARK: - Codex Data Source Section (D8'/D9/D12/D13)

    /// "Codex Data Source" 区块：CLI / Browser 两行 + 单选 + 回退提示 + 账户不一致警告。
    /// 放在既有账户列表卡片内，紧邻 `addAccountActionsView` 之上（phase-07 Implementation Step 3）。
    private var codexSourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.SettingsAuth.codexSourceTitle)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.top, 4)

            VStack(spacing: 2) {
                // CLI 已检测到但未启用时，这一行不是可选来源，而是 opt-in 入口：
                // 选中一个未启用的来源没有任何意义，radio 会变成死选项。
                if settings.isCodexCLIOptInPending {
                    cliOptInRow
                } else {
                    sourceRow(.cli)
                }
                sourceRow(.browser)
            }

            fallbackNote

            accountMismatchWarning
        }
    }

    /// CLI 一次性 opt-in 行：检测到 `~/.codex/auth.json`，但用户尚未同意本 App 使用它。
    /// 在用户点 Enable 之前，App 不会用 CLI 凭据发起任何网络请求，也不会改动菜单栏 / 弹窗 / 显示偏好。
    private var cliOptInRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal")
                .foregroundColor(.secondary)
                .font(.system(size: 14))
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(L.SettingsAuth.codexCliOptInTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                Text(L.SettingsAuth.codexCliOptInHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 同意已被自动撤回：磁盘上的 CLI 凭据换成了另一个 ChatGPT 账户。
                // 账户 id 本身永不展示，只说明「换了个账户」。
                if settings.codexCLIAccountChanged {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Text(L.SettingsAuth.codexCliAccountChanged)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }
            }

            Spacer()

            Button(action: {
                settings.setCodexCLIEnabled(true)
            }) {
                Text(L.SettingsAuth.codexCliEnable)
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    /// 单个来源行：单选 + 图标 + 标题 + 状态行 + 尾随控件（CLI 的 Re-scan / Disable）+ Active 标记。
    /// 复用 `accountRow` 的单选视觉习惯（largecircle.fill.circle / circle），而非 `Picker`，
    /// 以便保留每行的富文本内容（phase-07 Architecture）。
    private func sourceRow(_ source: CodexSource) -> some View {
        let isSelected = settings.codexSource == source
        let isActive = settings.effectiveCodexSource == source
        let accentColor: Color = Color(red: 45 / 255.0, green: 212 / 255.0, blue: 191 / 255.0)

        return Button(action: {
            settings.codexSource = source
        }) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? accentColor : .secondary)
                    .font(.system(size: 14))
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(sourceTitle(source))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)

                        if isActive {
                            Text(L.SettingsAuth.codexSourceActive)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(accentColor)
                                .cornerRadius(4)
                        }
                    }

                    Text(sourceStateLine(source))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let hint = sourceHint(source) {
                        Text(hint)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                if source == .cli {
                    Button(action: {
                        settings.refreshCodexCLIState()
                    }) {
                        Text(L.SettingsAuth.codexRescan)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)

                    // 关闭 opt-in：一个刷新周期内 Codex 会从图表 / 菜单栏 / 弹窗中完全消失
                    if settings.codexCLIEnabled {
                        Button(action: {
                            settings.setCodexCLIEnabled(false)
                        }) {
                            Text(L.SettingsAuth.codexCliDisable)
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? accentColor.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sourceTitle(_ source: CodexSource) -> String {
        switch source {
        case .cli: return L.SettingsAuth.codexSourceCli
        case .browser: return L.SettingsAuth.codexSourceBrowser
        }
    }

    /// 状态行文案：CLI 的 5 种 `CodexCLIAuthError`中，`.notInstalled`（缺失）与
    /// `.sandboxDenied`/`.malformed`/`.noAccessToken`（存在但不可读/不可解析）使用不同文案，
    /// 不合并成一句话；`.tokenExpired`（D13）单独一行，既不等同"未签入"也不等同"不可读"。
    private func sourceStateLine(_ source: CodexSource) -> String {
        switch source {
        case .cli:
            // 已 opt-in 但当前读不到凭据文件：既不是"没启用"也不是"能用"，单独一行说清楚，
            // 免得用户以为自己的同意被悄悄丢了。修复方式由 `sourceHint` 给出。
            if settings.codexCLIEnabled && !settings.codexCLIDetected {
                return L.SettingsAuth.codexCliEnabledMissing
            }
            if let error = settings.codexCLIError {
                switch error {
                case .tokenExpired:
                    return L.SettingsAuth.codexCliExpired
                case .notInstalled:
                    return L.SettingsAuth.codexCliNotDetected
                case .sandboxDenied, .malformed, .noAccessToken:
                    return L.SettingsAuth.codexCliMalformed
                }
            }
            if settings.codexCLIDetected {
                var line = L.SettingsAuth.codexCliDetected
                if let label = settings.codexCLIAccountLabel, !label.isEmpty {
                    line += " · \(label)"
                }
                if let plan = settings.codexCLIPlanType, !plan.isEmpty {
                    line += " (\(plan))"
                }
                return line
            }
            return L.SettingsAuth.codexCliNotDetected

        case .browser:
            if settings.isBrowserSourceConfigured, let account = settings.currentCodexAccount {
                return account.displayName
            }
            return L.SettingsAuth.codexCliNotDetected
        }
    }

    /// 尾随提示：仅 CLI 行在"未安装"或"已过期"时展示；权限/解析错误不建议用户瞎猜修复方式。
    private func sourceHint(_ source: CodexSource) -> String? {
        guard source == .cli, let error = settings.codexCLIError else { return nil }
        switch error {
        case .tokenExpired:
            return L.SettingsAuth.codexCliExpiredHint
        case .notInstalled:
            return L.SettingsAuth.codexCliHint
        case .sandboxDenied, .malformed, .noAccessToken:
            return nil
        }
    }

    /// `effectiveCodexSource` 因用户偏好来源不可用而回退时的提示（可用性说明，非失败提示）。
    @ViewBuilder
    private var fallbackNote: some View {
        if settings.codexSourceIsFallback, let effective = settings.effectiveCodexSource {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundColor(.orange)
                Text(String(format: L.SettingsAuth.codexSourceFallback, sourceTitle(settings.codexSource), sourceTitle(effective)))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    /// D12：两个来源都已配置，且 ChatGPT account id 不同时的提醒。账户 id 本身永不展示。
    /// - Important: 两个 id 都非 nil 且不相等时才触发；任一为 nil（尚未成功请求过、解析失败）
    /// 一律保持沉默，不做误判性提示。
    @ViewBuilder
    private var accountMismatchWarning: some View {
        if settings.isCLISourceConfigured, settings.isBrowserSourceConfigured,
           let cliId = settings.codexCLIChatGPTAccountId,
           let browserId = settings.codexBrowserChatGPTAccountId,
           cliId != browserId {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                Text(L.SettingsAuth.codexAccountMismatch)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(6)
            .padding(.top, 2)
        }
    }

    private var addAccountActionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.Account.addAccount)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                addAccountActionButton(
                    provider: .claude,
                    title: L.WebLogin.browserLogin,
                    help: "\(ProviderType.claude.displayName) \(L.WebLogin.browserLogin)"
                ) {
                    WebLoginWindowManager.shared.showLoginWindow()
                }

                addAccountActionButton(
                    provider: .claude,
                    title: L.WebLogin.manualInput,
                    help: L.SettingsAuth.manualInputClaudeOnlyHelp
                ) {
                    withAnimation {
                        isAddingAccount = true
                        newSessionKey = ""
                        newAlias = ""
                        validationError = nil
                    }
                }

                addAccountActionButton(
                    provider: .codex,
                    title: L.WebLogin.browserLogin,
                    help: "\(ProviderType.codex.displayName) \(L.WebLogin.browserLogin)"
                ) {
                    WebLoginWindowManager.shared.showCodexLoginWindow()
                }
            }
        }
        .padding(.top, 8)
    }

    private func addAccountActionButton(
        provider: ProviderType,
        title: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                providerIcon(provider: provider, size: 16)

                Text(title)
                    .font(.subheadline)
            }
        }
        .buttonStyle(.bordered)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func providerIcon(provider: ProviderType, size: CGFloat) -> some View {
        switch provider {
        case .claude:
            if let icon = ImageHelper.createAppIcon(size: size) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "sparkles")
                    .frame(width: size, height: size)
            }
        case .codex:
            if let icon = ImageHelper.createCodexIcon(size: size) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "sparkles")
                    .frame(width: size, height: size)
            }
        case .antigravity:
            // `createAntigravityIcon` 资源缺失时返回 nil，回退到占位符号，不崩溃、不留空白。
            if let icon = ImageHelper.createAntigravityIcon(size: size) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "sparkles")
                    .frame(width: size, height: size)
            }
        }
    }

    private func providerSectionHeader(provider: ProviderType, label: String) -> some View {
        HStack(spacing: 4) {
            switch provider {
            case .codex:
                if let icon = ImageHelper.createCodexIcon(size: 12) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 12, height: 12)
                }
            case .claude:
                if let icon = ImageHelper.createAppIcon(size: 12) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 12, height: 12)
                }
            case .antigravity:
                if let icon = ImageHelper.createAntigravityIcon(size: 12) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 12, height: 12)
                }
            }
            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            Divider()
                .frame(height: 10)
        }
    }

    // MARK: - Account Row

    /// - Important: `provider` 只应该是 `.claude`/`.codex`——Antigravity 走完全不同的
    /// `antigravityAccountRow`（多账户、颜色选择器旁边是 Sign out/Disable 而不是单一的当前账户
    /// 详情卡片）。`accountListView` 从未以 `.antigravity` 调用过这个函数；三处 `.antigravity`
    /// 分支此前只是复制粘贴出来的死代码，从未被真正执行到。
    private func accountRow(account: Account, provider: ProviderType) -> some View {
        let isSelected: Bool
        switch provider {
        case .codex:
            isSelected = account.id == settings.currentCodexAccountId
        case .claude:
            isSelected = account.id == settings.currentAccountId
        case .antigravity:
            // 不可达（见函数头注释），但用 `preconditionFailure` 守卫一个纯 UI 分支在 release
            // 构建里会直接 trap 掉整个 App——换成一个良性兜底值。
            Logger.settings.fault("accountRow(_:provider:) called with .antigravity — this should never happen")
            isSelected = false
        }

        let accentColor: Color
        switch provider {
        case .codex:
            accentColor = Color(red: 45/255.0, green: 212/255.0, blue: 191/255.0)
        case .claude:
            accentColor = .blue
        case .antigravity:
            Logger.settings.fault("accountRow(_:provider:) called with .antigravity — this should never happen")
            accentColor = .secondary
        }

        let colorBinding = Binding<AccountColor>(
            get: { account.color },
            set: { settings.updateAccountColor(accountId: account.id, to: $0) }
        )

        return HStack(spacing: 12) {
            Button(action: {
                switch provider {
                case .codex:
                    settings.switchToCodexAccount(account)
                case .claude:
                    settings.switchToAccount(account)
                case .antigravity:
                    Logger.settings.fault("accountRow(_:provider:) tapped with .antigravity — this should never happen")
                }
            }) {
                HStack(spacing: 12) {
                    // 选中状态指示器
                    Circle()
                        .fill(isSelected ? accentColor : Color.clear)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                        )

                    // 账户信息
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(account.displayName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)

                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                                    .foregroundColor(accentColor)
                            }
                        }

                        if account.alias != nil && !account.alias!.isEmpty {
                            Text(account.organizationName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            AccountColorSwatchPicker(selection: colorBinding)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? accentColor.opacity(0.1) : Color.clear)
        )
    }

    // MARK: - Current Account Detail View

    private func currentAccountDetailView(account: Account) -> some View {
        SettingCard(
            icon: "person.circle.fill",
            iconColor: .green,
            title: L.Account.currentAccount,
            hint: ""
        ) {
            VStack(alignment: .leading, spacing: 16) {
                // 别名编辑
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "tag.fill")
                            .foregroundColor(.orange)
                            .font(.subheadline)
                        Text(L.Account.alias)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }

                    HStack {
                        TextField(account.organizationName, text: Binding(
                            get: { account.alias ?? "" },
                            set: { newValue in
                                settings.updateAccount(account, alias: newValue.isEmpty ? nil : newValue)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)

                        if account.alias != nil && !account.alias!.isEmpty {
                            Button(action: {
                                settings.updateAccount(account, alias: nil)
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(L.Account.clearAlias)
                        }
                    }
                }

                // Session Key 显示
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill")
                            .foregroundColor(.red)
                            .font(.subheadline)
                        Text(L.SettingsAuth.sessionKeyLabel)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }

                    HStack {
                        if isShowingPassword {
                            Text(account.sessionKey)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(String(repeating: "•", count: min(account.sessionKey.count, 30)))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button(action: {
                            isShowingPassword.toggle()
                        }) {
                            Image(systemName: isShowingPassword ? "eye.slash.fill" : "eye.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(isShowingPassword ? L.SettingsAuth.hidePassword : L.SettingsAuth.showPassword)
                    }
                }

                // Organization ID 显示
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "building.2.fill")
                            .foregroundColor(.purple)
                            .font(.subheadline)
                        Text(L.Account.organizationId)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }

                    HStack {
                        Text(account.organizationId)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(account.organizationId, forType: .string)
                        }) {
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L.Account.copyOrgId)
                    }
                }

                // 删除按钮
                if settings.accounts.count > 0 {
                    Divider()

                    Button(action: {
                        accountToDelete = account
                        showDeleteConfirmation = true
                    }) {
                        HStack {
                            Image(systemName: "trash.fill")
                            Text(L.Account.deleteAccount)
                        }
                        .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Current Codex Account Detail View

    private func currentCodexAccountDetailView(account: Account) -> some View {
        SettingCard(
            icon: "person.circle.fill",
            iconColor: Color(red: 13/255.0, green: 148/255.0, blue: 136/255.0),
            title: L.Account.codexCurrentAccount,
            hint: ""
        ) {
            VStack(alignment: .leading, spacing: 16) {
                // 别名编辑
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "tag.fill")
                            .foregroundColor(.orange)
                            .font(.subheadline)
                        Text(L.Account.alias)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }

                    HStack {
                        TextField(account.organizationName, text: Binding(
                            get: { account.alias ?? "" },
                            set: { newValue in
                                settings.updateCodexAccount(account, alias: newValue.isEmpty ? nil : newValue)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)

                        if account.alias != nil && !account.alias!.isEmpty {
                            Button(action: {
                                settings.updateCodexAccount(account, alias: nil)
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(L.Account.clearAlias)
                        }
                    }
                }

                // Session Token 显示
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill")
                            .foregroundColor(.red)
                            .font(.subheadline)
                        Text(L.SettingsAuth.sessionKeyLabel)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }

                    HStack {
                        Text(String(repeating: "•", count: min(account.sessionKey.count, 30)))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)

                        Spacer()
                    }
                }

                // 删除按钮
                Divider()

                Button(action: {
                    codexAccountToDelete = account
                    showDeleteCodexConfirmation = true
                }) {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text(L.Account.deleteAccount)
                    }
                    .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Antigravity Section

    /// Antigravity 强调色（紫）：直接调用 `UsageColorScheme.antigravityPrimaryColorSwiftUI`
    /// 本身（警告档 75%），而不是誊抄它的输出字面量——否则那六个函数在全项目里没有一个真正
    /// 调用方。
    private var antigravityAccentColor: Color {
        UsageColorScheme.antigravityPrimaryColorSwiftUI(75, opacity: 1)
    }

    private var antigravitySection: some View {
        SettingCard(
            icon: "sparkles",
            iconColor: antigravityAccentColor,
            title: L.SettingsAuth.antigravitySectionTitle,
            hint: ""
        ) {
            VStack(alignment: .leading, spacing: 12) {
                antigravitySignInRow

                if settings.antigravityKeychainDetected {
                    Divider().padding(.vertical, 2)
                    antigravityKeychainSourceRow
                }

                if settings.hasAntigravityOAuthAccounts && settings.hasAntigravityKeychainSource {
                    antigravitySourcePreferenceRow
                }

                if !settings.antigravityAccounts.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text(L.SettingsAuth.antigravityAccountsTitle)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    ForEach(settings.antigravityAccounts) { account in
                        antigravityAccountRow(account: account)
                    }
                }

                // Keychain 身份与某个 OAuth 账户重复时，伪账户本身已被
                // `syncAntigravityKeychainAccountVisibility()` 整条移除，
                // 这里只需要一行说明，告诉用户"为什么钥匙串来源看起来什么都没有"。
                if settings.hasAntigravityKeychainSource && settings.isAntigravityKeychainAccountRedundant {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(L.SettingsAuth.antigravityDedupeLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    /// "Sign in with Google" 主按钮 + 说明。已经有 OAuth 账户时按钮文案改为"添加另一个账户"，
    /// 而不是重复展示说明文字（说明只在第一次出现）。
    private var antigravitySignInRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !settings.hasAntigravityOAuthAccounts {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text(L.SettingsAuth.antigravitySignInExplainer)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: startAntigravitySignIn) {
                HStack(spacing: 8) {
                    providerIcon(provider: .antigravity, size: 16)
                    Text(settings.hasAntigravityOAuthAccounts ? L.SettingsAuth.antigravitySignInAnother : L.SettingsAuth.antigravitySignInButton)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// 钥匙串来源行：Enable / Connect / Disable / Reconnect 四个主要状态，外加"从未连接"这一纯提示
    /// 状态（无按钮）。
    /// - Important: 这里 **Connect / Reconnect 是全 App 唯一** 会触发
    /// `AntigravityCredentialStore.read()` 的用户手势——直接调用
    /// `AntigravityTokenProvider.shared.connectKeychain(_:)`，而不是像修复前那样翻一个
    /// `antigravityKeychainEnabled` 开关、指望 `DataRefreshManager` 的下一次拉取周期"顺便"去读
    /// 钥匙串。`Enable`/`Disable` 只翻开关本身，从不触发任何 I/O。
    @ViewBuilder
    private var antigravityKeychainSourceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "key.horizontal")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L.SettingsAuth.antigravityKeychainRowTitle)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(antigravityKeychainStateLine)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let hint = antigravityKeychainHint {
                        Text(hint)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                antigravityKeychainTrailingButton
            }

            // `antigravityKeychainAccountChanged` 与访问被拒绝（`antigravityKeychainAccessDenied`）
            // 是两个独立的 `@Published` 状态，理论上可能同时为真；两者现在使用完全不同的文案
            // （分别说明"需要重新授权"与"钥匙串换了个 Google 身份"两件不同的事），不会在同一行
            // 里重复出现同一句话。
            if settings.antigravityKeychainAccountChanged {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text(L.SettingsAuth.antigravityKeychainIdentityChangedReason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // `antigravityKeychainConnectTapped` 只应该在它自己触发的那次 Connect/Reconnect 期间
        // 显示 spinner；一旦已经解析出身份，或者已经被禁用，都必须清掉这个标记——否则用户从未
        // 点过的行也会在本次设置页会话剩余时间里一直显示 spinner。
        .onChange(of: antigravityKeychainResolved) { resolved in
            if resolved { antigravityKeychainConnectTapped = false }
        }
        .onChange(of: settings.antigravityKeychainEnabled) { enabled in
            if !enabled { antigravityKeychainConnectTapped = false }
            // Enable 按钮本身是同步调用，没有真正的异步等待窗口——这里只是让它和 Connect 一样在
            // `enabled` 翻为 true 之后的下一次渲染里清掉 spinner，视觉上保持两个按钮一致。
            if enabled { antigravityKeychainEnableTapped = false }
        }
    }

    /// 钥匙串账户是否已经解析出真实身份（占位名 "Antigravity" 被替换为邮箱）。
    private var antigravityKeychainResolved: Bool {
        guard let account = settings.antigravityKeychainAccount else { return false }
        return account.organizationName != "Antigravity"
    }

    /// 钥匙串来源当前是否处于"访问被拒绝，需要 Reconnect"的错误态——这里不可区分"用户点了拒绝"
    /// 与"系统出于其它原因阻止了交互"，文案（`antigravityKeychainReconnectReason`）也不应该断言
    /// 一个我们其实并不知道的具体原因。
    private var antigravityKeychainAccessDenied: Bool {
        guard let authError = settings.antigravityError?.underlying as? AntigravityAuthError else { return false }
        switch authError {
        case .keychainAccessDenied, .keychainEntitlementMissing:
            return true
        default:
            return false
        }
    }

    /// 除访问被拒绝之外的其它失败（`keychainMalformed`、`noAccessToken`、`keychainNotConnected`、
    /// `subscriptionRequired`、`refreshTokenRevoked`，以及 `AntigravityAPIService` 传输层的
    /// `UsageError`）消费 `AntigravitySourceError.authTabDescription`。
    private var antigravityKeychainOtherErrorDescription: String? {
        guard let error = settings.antigravityError else { return nil }
        if antigravityKeychainAccessDenied { return nil }
        return error.authTabDescription
    }

    /// Connect/Reconnect 点击之后、结果（成功解析出身份 或 失败记录进 `antigravityError`）
    /// 落地之前的过渡态——直接对应 `AntigravityTokenProvider.shared.connectKeychain(_:)` 仍在
    /// 后台队列读钥匙串/刷新 token，尚未回调。
    private var antigravityKeychainConnecting: Bool {
        antigravityKeychainConnectTapped && settings.antigravityError == nil && !antigravityKeychainResolved
    }

    private var antigravityKeychainStateLine: String {
        guard settings.antigravityKeychainEnabled else {
            return L.SettingsAuth.antigravityKeychainRowHint
        }
        if antigravityKeychainConnecting {
            return L.SettingsAuth.antigravityKeychainConnecting
        }
        // 访问被拒绝时，状态行必须说明*原因*，不能复述按钮自己的文案（"Reconnect Reconnect"
        // 读起来像没写完）——原因文案就是 `antigravityKeychainReconnectReason`。
        if antigravityKeychainAccessDenied {
            return L.SettingsAuth.antigravityKeychainReconnectReason
        }
        if antigravityKeychainResolved, let account = settings.antigravityKeychainAccount {
            return "\(account.displayName) · \(L.SettingsAuth.antigravityViaKeychain)"
        }
        if let description = antigravityKeychainOtherErrorDescription {
            return description
        }
        return L.SettingsAuth.antigravityKeychainNotConnected
    }

    private var antigravityKeychainHint: String? {
        guard settings.antigravityKeychainEnabled else { return nil }
        if antigravityKeychainConnecting { return nil }
        if antigravityKeychainAccessDenied { return nil }
        if antigravityKeychainOtherErrorDescription != nil { return nil }
        if !antigravityKeychainResolved { return L.SettingsAuth.antigravityKeychainConnectHint }
        return nil
    }

    /// Connect/Reconnect 共用的点击处理：唯一调用 `AntigravityTokenProvider.shared.connectKeychain(_:)`
    /// 的地方——这本身就是本 App 里唯一允许触发 `AntigravityCredentialStore.read()` 的用户手势。
    /// 成功后广播一次 `.accountChanged` 促成
    /// 立即拉取/身份解析，而不是等下一个 5 分钟节流周期；失败则把错误直接记录进
    /// `settings.antigravityError`，因为这次失败根本没有经过 `DataRefreshManager` 的拉取流水线。
    private func connectAntigravityKeychain() {
        antigravityKeychainConnectTapped = true
        AntigravityTokenProvider.shared.connectKeychain { result in
            switch result {
            case .success:
                // 伪账户的可见性跟着这一位走——connect 成功之前它永远不会被拉取，
                // 因此在此之前不该出现在任何账户列表里（见 `antigravityKeychainConnected`）。
                settings.setAntigravityKeychainConnected(true)
                settings.recordAntigravityKeychainError(nil)
                NotificationCenter.default.post(
                    name: .accountChanged,
                    object: nil,
                    userInfo: [Notification.UserInfoKey.provider: ProviderType.antigravity.rawValue]
                )
            case .failure(let error):
                antigravityKeychainConnectTapped = false
                settings.setAntigravityKeychainConnected(false)
                settings.recordAntigravityKeychainError(AntigravitySourceError(source: .keychain, underlying: error))
            }
        }
    }

    @ViewBuilder
    private var antigravityKeychainTrailingButton: some View {
        if !settings.antigravityKeychainEnabled {
            // `setAntigravityKeychainEnabled(true)` 内部已经在末尾无条件 `postAccountChanged`
            // 一次——这里不需要再手动广播一次同样的通知。这里只是翻开关 + 探测条目是否存在，
            // 不读取任何数据、不触发任何 I/O。
            Button(action: {
                antigravityKeychainEnableTapped = true
                settings.setAntigravityKeychainEnabled(true)
                // `setAntigravityKeychainEnabled(true)` 是同步调用，若条目在按钮渲染之后、点击
                // 之前恰好消失，内部 guard 会直接返回而不翻开关——那样 `enabled` 永远不会变成
                // true，下面 `.onChange(of: settings.antigravityKeychainEnabled)` 也就永远不会
                // 触发，spinner 会卡住。这里立即核对一次调用后的实际状态，失败就自己清掉。
                if !settings.antigravityKeychainEnabled {
                    antigravityKeychainEnableTapped = false
                }
            }) {
                HStack(spacing: 6) {
                    if antigravityKeychainEnableTapped {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    }
                    Text(L.SettingsAuth.antigravityKeychainEnable)
                        .font(.caption)
                }
            }
            .buttonStyle(.bordered)
        } else if antigravityKeychainAccessDenied {
            // Reconnect：再打一次真实的 `AntigravityCredentialStore.read()`（同 Connect），而不是
            // 像修复前那样翻两次 `setAntigravityKeychainEnabled` 去间接放行一次轮询里的读取。
            HStack(spacing: 6) {
                if antigravityKeychainConnecting {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                }
                Button(action: connectAntigravityKeychain) {
                    Text(L.SettingsAuth.antigravityKeychainReconnect)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        } else if !antigravityKeychainResolved {
            HStack(spacing: 6) {
                if antigravityKeychainConnecting {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                }
                Button(action: connectAntigravityKeychain) {
                    Text(L.SettingsAuth.antigravityKeychainConnect)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        } else {
            Button(action: { settings.setAntigravityKeychainEnabled(false) }) {
                Text(L.SettingsAuth.antigravityKeychainDisable)
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
    }

    /// 双来源都存活时的偏好选择（镜像 Codex 的 `sourceRow` 单选视觉）。
    private var antigravitySourcePreferenceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.SettingsAuth.antigravitySourcePreferenceTitle)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            Picker("", selection: Binding(
                get: { settings.preferredAntigravitySource },
                set: { settings.preferredAntigravitySource = $0 }
            )) {
                Text(L.SettingsAuth.antigravitySourceOAuth).tag(AntigravitySource.oauth)
                Text(L.SettingsAuth.antigravitySourceKeychain).tag(AntigravitySource.keychain)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// 单个 Antigravity 账户行：圆点 + 名称 + "via 来源" + 颜色选择器 + Sign out/Disable，
    /// 外加该账户的错误行（若有）。与 `accountRow` 不同——Antigravity 是多账户，删除操作
    /// 直接长在每一行上，不走单独的"当前账户详情卡片"。
    private func antigravityAccountRow(account: Account) -> some View {
        let isSelected = account.id == settings.currentAntigravityAccountId
        let isKeychainAccount = account.antigravitySource == .keychain
        let viaLabel = L.Account.antigravitySourceLabel(account.antigravitySource ?? .oauth)

        let colorBinding = Binding<AccountColor>(
            get: { account.color },
            set: { settings.updateAccountColor(accountId: account.id, to: $0) }
        )

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Button(action: { settings.switchToAntigravityAccount(account) }) {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(isSelected ? antigravityAccentColor : Color.clear)
                            .frame(width: 8, height: 8)
                            .overlay(
                                Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(account.displayName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundColor(antigravityAccentColor)
                                }
                            }
                            Text(viaLabel)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                AccountColorSwatchPicker(selection: colorBinding)

                Button(action: {
                    if isKeychainAccount {
                        // Keychain 伪账户的"Disable"必须关掉 Keychain **来源**本身
                        // （`antigravityKeychainEnabled` = false，连带清掉同意摘要/已解析邮箱、
                        // 并广播 `.accountChanged`），而不是只把这一行从列表里摘掉——否则拉取
                        // 流水线仍然认为这个来源已启用，继续读同一份钥匙串凭据，且下一次
                        // `syncAntigravityKeychainAccountVisibility()` 会把这一行重新变出来。
                        // 走 `removeAntigravityAccount` 对 Keychain
                        // 伪账户没有意义：它甚至不需要二次确认，同 CLI 行的 Disable 按钮一致。
                        settings.setAntigravityKeychainEnabled(false)
                    } else {
                        antigravityAccountToDelete = account
                        showDeleteAntigravityConfirmation = true
                    }
                }) {
                    Text(isKeychainAccount ? L.SettingsAuth.antigravityKeychainDisable : L.SettingsAuth.antigravitySignOut)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }

            // 单账户级别的拉取错误：`DataRefreshManager.mergeAntigravityResult` 把它同步镜像进
            // `UserSettings.antigravityAccountErrors`（这个视图层边界是既有设计——
            // `AuthSettingsView()` 在 `SettingsView` 里零依赖构造，不持有 `DataRefreshManager`
            // 引用），这里直接读即可。这里需要单独展示逐账户错误行——popover 的
            // provider 级错误行只在*全部*账户失败时出现，一个持续失败的单一账户
            // 此前在任何地方都不可见。Keychain 伪账户的失败单独经
            // `settings.antigravityError` 在上面的来源行里呈现，这里不重复展示，避免同一次失败
            // 出现两条一字不差的错误行。
            if !isKeychainAccount, let message = settings.antigravityAccountErrors[account.id] {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 20)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? antigravityAccentColor.opacity(0.1) : Color.clear)
        )
    }

    /// 启动 Antigravity 登录窗口；成功回调里同步调用 `addAntigravityOAuthAccount`，
    /// 并把它是否返回非 nil（身份是否确认）转发回登录视图（这个方法**不是**
    /// `@discardableResult`，nil 必须被处理，绝不能忽略）。
    private func startAntigravitySignIn() {
        WebLoginWindowManager.shared.showAntigravitySignInWindow { result in
            let account = settings.addAntigravityOAuthAccount(
                refreshToken: result.refreshToken,
                email: result.email,
                sub: result.sub
            )
            if let account {
                settings.switchToAntigravityAccount(account)
                return true
            }
            return false
        }
    }

    /// OAuth 账户的 Sign out：尽力撤销 refresh token，再无条件做本地清理——网络请求失败/超时
    /// 绝不能拖住甚至阻止本地删除，否则用户在离线状态下永远退不出这个账户（见
    /// `UserSettings.removeAntigravityAccount` 上的说明：撤销是调用方职责，那里本身不发请求）。
    /// 撤销发生在删除**之前**发起、但删除不等待它的结果——这两件事在网络上是独立的：
    /// 即使撤销的响应比本地清理慢，Google 那端最终也会看到这次撤销请求。
    private func signOutAntigravityAccount(_ account: Account) {
        if account.antigravitySource == .oauth, !account.sessionKey.isEmpty,
           let secrets = AntigravityOAuthSecrets.load() {
            let client = AntigravityOAuthClient(secrets: secrets)
            client.revoke(token: account.sessionKey) { result in
                switch result {
                case .success:
                    Logger.settings.notice("Antigravity refresh token 已撤销")
                case .failure:
                    // 尽力而为——撤销失败（离线、Google 那边已经先手撤销过了等）绝不阻止
                    // 本地清理，见方法头注释。
                    Logger.settings.notice("Antigravity refresh token 撤销失败，仍继续本地清理")
                }
            }
        }
        settings.removeAntigravityAccount(account)
    }

    // MARK: - Add Account View

    private var addAccountView: some View {
        SettingCard(
            icon: "person.badge.plus",
            iconColor: .blue,
            title: L.Account.addNewAccount,
            hint: ""
        ) {
            VStack(alignment: .leading, spacing: 16) {
                // Session Key 输入
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill")
                            .foregroundColor(.red)
                            .font(.subheadline)
                        Text(L.SettingsAuth.sessionKeyLabel)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }

                    SecureField(L.SettingsAuth.sessionKeyPlaceholder, text: $newSessionKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    // 验证状态提示
                    if !newSessionKey.isEmpty {
                        if settings.isValidSessionKey(newSessionKey) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                                Text(L.Welcome.validFormat)
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                                Text(L.Welcome.invalidFormat)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "lightbulb.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(L.SettingsAuth.sessionKeyHint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // 别名输入（可选）
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "tag.fill")
                            .foregroundColor(.orange)
                            .font(.subheadline)
                        Text(L.Account.aliasOptional)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }

                    TextField(L.Account.aliasPlaceholder, text: $newAlias)
                        .textFieldStyle(.roundedBorder)
                }

                // 错误提示
                if let error = validationError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                // 操作按钮
                HStack {
                    Button(action: {
                        withAnimation {
                            isAddingAccount = false
                        }
                    }) {
                        Text(L.Account.cancel)
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(action: {
                        validateAndAddAccount()
                    }) {
                        if isValidating {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                        } else {
                            Text(L.Account.validateAndAdd)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!settings.isValidSessionKey(newSessionKey) || isValidating)
                }
            }
        }
    }

    // MARK: - How To Card

    private var howToCard: some View {
        SettingCard(
            icon: "book.fill",
            iconColor: .blue,
            title: L.SettingsAuth.howToTitle,
            hint: ""
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.SettingsAuth.step1)
                    .font(.subheadline)
                Text(L.SettingsAuth.step2)
                    .font(.subheadline)
                Text(L.SettingsAuth.step3)
                    .font(.subheadline)
                Text(L.SettingsAuth.step4)
                    .font(.subheadline)
                Text(L.SettingsAuth.step5)
                    .font(.subheadline)
                Text(L.SettingsAuth.step6)
                    .font(.subheadline)

                Button(action: {
                    if let url = URL(string: "https://claude.ai/settings/usage") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack {
                        Image(systemName: "safari")
                        Text(L.SettingsAuth.openBrowser)
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Diagnostics Card

    private var diagnosticsCard: some View {
        SettingCard(
            icon: "stethoscope",
            iconColor: .blue,
            title: L.Diagnostic.sectionTitle,
            hint: ""
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.Diagnostic.sectionDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 诊断组件
                DiagnosticsView()
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Private Methods

    /// 验证并添加账户
    private func validateAndAddAccount() {
        isValidating = true
        validationError = nil

        let apiService = ClaudeAPIService()
        apiService.fetchOrganizations(sessionKey: newSessionKey) { result in
            DispatchQueue.main.async {
                isValidating = false

                switch result {
                case .success(let organizations):
                    if !organizations.isEmpty {
                        let useAlias = organizations.count == 1
                        for (index, org) in organizations.enumerated() {
                            let newAccount = Account(
                                sessionKey: newSessionKey,
                                organizationId: org.uuid,
                                organizationName: org.name,
                                alias: (useAlias && !newAlias.isEmpty) ? newAlias : nil
                            )
                            settings.addAccount(newAccount)
                            // 切换到第一个新添加的账户
                            if index == 0 {
                                settings.switchToAccount(newAccount)
                            }
                        }
                        // 多组织时显示提示
                        if organizations.count > 1 {
                            successMessage = String(format: L.Account.multiOrgAdded, organizations.count)
                        }
                        // 关闭添加界面
                        withAnimation {
                            isAddingAccount = false
                        }
                    } else {
                        validationError = L.Error.noOrganizationsFound
                    }
                case .failure(let error):
                    if let usageError = error as? UsageError {
                        validationError = usageError.localizedDescription
                    } else {
                        validationError = error.localizedDescription
                    }
                }
            }
        }
    }
}

/// 关于页面
/// 显示应用信息、版本号和相关链接
