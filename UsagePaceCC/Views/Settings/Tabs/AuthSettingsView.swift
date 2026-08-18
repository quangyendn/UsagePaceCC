//
//  AuthSettingsView.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2025-12-02.
//  Copyright © 2025 f-is-h. All rights reserved.
//

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

    /// 状态行文案：CLI 的 5 种 `CodexCLIAuthError`（P02）中，`.notInstalled`（缺失）与
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
    ///   一律保持沉默，不做误判性提示。
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
        }
    }

    private func providerSectionHeader(provider: ProviderType, label: String) -> some View {
        HStack(spacing: 4) {
            if provider == .codex, let icon = ImageHelper.createCodexIcon(size: 12) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 12, height: 12)
            } else if provider == .claude, let icon = ImageHelper.createAppIcon(size: 12) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 12, height: 12)
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

    private func accountRow(account: Account, provider: ProviderType) -> some View {
        let isSelected = provider == .codex
            ? account.id == settings.currentCodexAccountId
            : account.id == settings.currentAccountId
        let accentColor: Color = provider == .codex
            ? Color(red: 45/255.0, green: 212/255.0, blue: 191/255.0)
            : .blue

        return Button(action: {
            if provider == .codex {
                settings.switchToCodexAccount(account)
            } else {
                settings.switchToAccount(account)
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
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? accentColor.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
