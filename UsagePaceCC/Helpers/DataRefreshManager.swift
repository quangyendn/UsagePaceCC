//
//  DataRefreshManager.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2025-12-01.
//  Copyright © 2025 f-is-h. All rights reserved.
//

import Foundation
import Combine
import OSLog
import AppKit

/// 数据刷新管理器
/// 负责管理所有数据刷新、定时器、更新检查和重置验证逻辑
class DataRefreshManager: ObservableObject {

    // MARK: - Dependencies

    /// 每账户一个 Claude API 服务实例，惰性创建，账户删除时清理
    /// （不可跨账户共享单一实例：`ClaudeAPIService.currentTask?.cancel()` 会让账户 B 的请求取消账户 A 的请求）
    private var claudeServices: [UUID: ClaudeAPIService] = [:]
    /// Codex API 服务实例
    private let codexApiService = CodexAPIService()
    /// Antigravity token provider：**必须**用全 App 唯一的 `.shared` 实例，而不是自己另建一份——
    /// `AuthSettingsView` 的 Connect/Reconnect 按钮直接调用同一个单例的 `connectKeychain(_:)`
    /// 把凭据写进内存，这里的周期性拉取必须读到同一份内存状态，否则两边各自拿着一份互不相通的
    /// "是否已连接"记忆，Connect 按钮形同虚设。
    private let antigravityTokenProvider = AntigravityTokenProvider.shared
    /// Antigravity API 服务（单实例，按账户 id 分别限流）
    private lazy var antigravityApiService = AntigravityAPIService(tokenProvider: antigravityTokenProvider)
    /// 更新检查器实例
    private let updateChecker = UpdateChecker()
    /// 定时器管理器
    private let timerManager = TimerManager()
    /// 用户设置实例
    private let settings = UserSettings.shared

    // MARK: - Published State

    /// Claude 用量数据（向后兼容属性：每次合并后从 `settings.accounts` 中排在第一位的 Claude 账户赋值）
    @Published var usageData: UsageData?
    /// 按账户 ID 索引的 Claude 用量数据（多账户全量拉取）
    @Published var claudeUsageByAccount: [UUID: UsageData] = [:]
    /// 按账户 ID 索引的 Claude 错误信息；某账户拉取失败不影响其他账户的数据
    @Published var claudeErrorByAccount: [UUID: String] = [:]
    /// 每账户一份用于渲染的用量快照，顺序与 `settings.accounts` 一致
    @Published var claudeSnapshots: [AccountUsageSnapshot] = []
    /// Codex 用量数据（nil 表示无 Codex 账号或拉取失败）
    @Published var codexUsageData: CodexUsageData?
    /// 按账户 id 索引的 Antigravity 用量数据（与 `claudeUsageByAccount` 的多账户模型对齐）
    @Published var antigravityUsageByAccount: [UUID: AntigravityUsageData] = [:]
    /// 按账户 id 索引的 Antigravity 错误信息；独立于 Claude/Codex，避免三 Provider 时被静默隐藏
    @Published var antigravityErrorByAccount: [UUID: String] = [:]
    /// 按账户 id 索引的、最近一次实际服务了该账户数据的凭据来源；用于在设置页显示
    /// "via Antigravity app" / "via Google sign-in"。
    @Published var antigravityLastServingSourceByAccount: [UUID: AntigravitySource] = [:]
    /// 每账户一份用于渲染的用量快照，与 `claudeSnapshots` 同一形状，走
    /// `PopoverLayout.legendItems` 的 Claude 分支同款的账户驱动渲染路径。出错的账户保留它上一次
    /// 的数据继续产出快照，同 Claude（见 `AccountUsageSnapshot.antigravitySnapshot`），
    /// 重建时机见 `rebuildAntigravitySnapshots()`。
    @Published var antigravitySnapshots: [AccountUsageSnapshot] = []
    /// 加载状态
    @Published var isLoading = false
    /// 错误消息
    @Published var errorMessage: String?
    /// Codex 错误消息（独立于 Claude，避免双 Provider 时被静默隐藏）
    @Published var codexErrorMessage: String?
    /// 是否有可用更新
    @Published var hasAvailableUpdate = false
    /// 最新版本号
    @Published var latestVersion: String?
    /// 刷新状态管理器
    let refreshState = RefreshState()

    // MARK: - Private State

    /// Claude 每账户上次的重置时间（用于检测重置是否完成），按账户 ID 索引
    private var lastResetsAtByAccount: [UUID: Date] = [:]
    /// Codex 上次的重置时间
    private var lastCodexResetsAt: Date?
    /// 上次手动刷新时间
    private var lastManualRefreshTime: Date?
    /// 上次API请求时间
    private var lastAPIFetchTime: Date?
    /// 刷新动画开始时间（用于确保动画最小显示时长）
    private var refreshAnimationStartTime: Date?
    /// 动画最小显示时长（秒）
    private let minimumAnimationDuration: TimeInterval = 1.0
    /// 上次检查更新时间
    private var lastUpdateCheckTime: Date?
    /// App Nap 防护活动令牌
    private var refreshActivity: NSObjectProtocol?
    /// 系统唤醒观察者令牌
    private var wakeObserver: NSObjectProtocol?
    /// 标记当前是否正处于 `fetchUsage()` 内部的 CLI 状态同步阶段
    /// 用于抑制该同步触发的 `.accountChanged` 通知在 `handleAccountChanged` 中发起的重复 Codex 请求
    /// （一个刷新周期只应产生一次 Codex 请求）
    private var isSyncingCodexCLIState = false
    /// 标记当前是否正处于 `fetchUsage()` 内部的 Antigravity Keychain 状态同步阶段（同上，
    /// 目前 `refreshAntigravityKeychainState()` 只在来源消失时才可能触发 `.accountChanged`，
    /// 这里保留标记位是为了与 Codex 保持同一套约定，方便后续如需抑制重复请求时复用）。
    private var isSyncingAntigravityKeychainState = false
    /// 上一次 `pruneAntigravityAccountState()` 观测到的 `settings.antigravityAccounts` id 全集；
    /// 用于计算真正被移除的账户，而不是"曾经记录过数据的账户"。在 `init()`
    /// 里用启动时已持久化的账户列表播种，否则本次会话第一次账户变化事件发生时，一个"启动时就
    /// 存在、这是它第一次被移除"的账户会因为 `knownAntigravityAccountIds` 还是空集而检测不到。
    private var knownAntigravityAccountIds: Set<UUID> = []

    private var shouldFetchClaudeUsage: Bool {
        #if DEBUG
        if shouldSuppressDebugClaudeUsageForDisplayOptions {
            return false
        }
        return settings.debugModeEnabled || settings.hasValidCredentials
        #else
        return settings.hasValidCredentials
        #endif
    }

    private var shouldSuppressDebugClaudeUsageForDisplayOptions: Bool {
        #if DEBUG
        return settings.debugModeEnabled
            && settings.displayMode == .custom
            && !settings.customDisplayTypes.contains { $0.provider == .claude }
        #else
        return false
        #endif
    }

    private var shouldSuppressDebugCodexUsageForDisplayOptions: Bool {
        #if DEBUG
        return settings.debugModeEnabled
            && settings.displayMode == .custom
            && !settings.customDisplayTypes.contains { $0.provider == .codex }
        #else
        return false
        #endif
    }

    private var shouldFetchCodexUsage: Bool {
        #if DEBUG
        if shouldSuppressDebugCodexUsageForDisplayOptions {
            return false
        }
        return settings.debugModeEnabled || settings.hasValidCodexCredentials
        #else
        return settings.hasValidCodexCredentials
        #endif
    }

    private var shouldSuppressDebugAntigravityUsageForDisplayOptions: Bool {
        #if DEBUG
        return settings.debugModeEnabled
            && settings.displayMode == .custom
            && !settings.customDisplayTypes.contains { $0.provider == .antigravity }
        #else
        return false
        #endif
    }

    private var shouldFetchAntigravityUsage: Bool {
        #if DEBUG
        if shouldSuppressDebugAntigravityUsageForDisplayOptions {
            return false
        }
        return settings.debugModeEnabled || settings.hasValidAntigravityCredentials
        #else
        return settings.hasValidAntigravityCredentials
        #endif
    }

    /// Provider 级错误行文案。规则刻意与 Codex 不同——Codex 单账户失败即整体顶替，
    /// Antigravity 是多账户，单个账户失败会保留它上一次的数据继续渲染（同 Claude，见
    /// `AccountUsageSnapshot.antigravitySnapshot` 上的说明），不会让那一行消失。
    /// 这里只负责挑一条"代表性"错误文案；是否真的要显示成一整行 provider 级错误，由
    /// `PopoverLayout.rowCount`/`legendItems` 组合判断——只有当 `antigravitySnapshots` 里
    /// 完全没有任何一行时才会真正显示（即全部账户都失败且从未有过数据，或全部账户都还没
    /// 成功加载过且已有错误）。按 `settings.antigravityAccounts` 的顺序取第一条已记录的错误，
    /// 保证跨调用确定性。
    var antigravityProviderErrorMessage: String? {
        guard !settings.antigravityAccounts.isEmpty else { return nil }
        for account in settings.antigravityAccounts {
            if let error = antigravityErrorByAccount[account.id] {
                return error
            }
        }
        return nil
    }

    /// 当前应该实际拉取的 Antigravity 账户列表：过滤掉
    /// 1) 与 OAuth 账户重复的 Keychain 伪账户（见 `UserSettings.isAntigravityKeychainAccountRedundant`），
    ///    避免同一份配额被拉两次；
    /// 2) 尚未有内存态 Keychain 凭据的 Keychain 伪账户——`AntigravityTokenProvider.shared` 从未
    ///    成功执行过一次用户手势触发的 `connectKeychain(_:)`（或上一次失败了），此时这个来源
    ///    "贡献零次拉取"，而不是让 `fetchAntigravityOnly` 走到 `accessToken(source: .keychain, ...)`
    ///    后以 `.keychainNotConnected` 收场——那样虽然不会弹窗，但每一轮定时器/`.accountChanged`
    ///    都会记一次可见错误，且行为上仍然像是"尝试过读取"。
    private var antigravityAccountsToFetch: [Account] {
        settings.antigravityAccounts.filter { account in
            guard account.id == settings.antigravityKeychainAccount?.id else { return true }
            guard !settings.isAntigravityKeychainAccountRedundant else { return false }
            return antigravityTokenProvider.hasKeychainCredential
        }
    }

    // MARK: - Timer Identifiers

    /// 定时器标识符
    private enum TimerID {
        static let mainRefresh = "mainRefresh"
        static let popoverRefresh = "popoverRefresh"
        static let resetVerify1 = "resetVerify1"
        static let resetVerify2 = "resetVerify2"
        static let resetVerify3 = "resetVerify3"
        static let codexResetVerify1 = "codexResetVerify1"
        static let codexResetVerify2 = "codexResetVerify2"
        static let codexResetVerify3 = "codexResetVerify3"
        static let dailyUpdate = "dailyUpdate"
    }

    /// 按账户拼接重置验证定时器 ID，避免账户 B 的重置取消/覆盖账户 A 的验证
    private func resetVerifyTimerId(_ base: String, accountId: UUID) -> String {
        "\(base):\(accountId.uuidString)"
    }

    // MARK: - Claude Window Constants

    /// Claude 5 小时窗口时长（秒）：固定值，非数据驱动（与 Codex 不同，Codex 的窗口时长来自 API 响应）
    private static let claudeFiveHourWindowSeconds: TimeInterval = 18000
    /// Claude 7 天窗口时长（秒）：固定值，非数据驱动
    private static let claudeSevenDayWindowSeconds: TimeInterval = 604800

    // MARK: - Initialization

    init() {
        scheduleDailyUpdateCheck()
        setupWakeObserver()
        // 用启动时已持久化的 Antigravity 账户 id 全集播种，见上面 `knownAntigravityAccountIds`
        // 的注释。
        knownAntigravityAccountIds = Set(settings.antigravityAccounts.map(\.id))
    }

    // MARK: - Per-Account Claude Services

    /// 获取（惰性创建）指定账户的 `ClaudeAPIService` 实例
    /// - Important: 不可跨账户共享同一实例，否则后发起的账户请求会取消先发起的账户请求
    private func claudeService(for account: Account) -> ClaudeAPIService {
        if let existing = claudeServices[account.id] {
            return existing
        }
        let service = ClaudeAPIService(account: account)
        claudeServices[account.id] = service
        return service
    }

    // MARK: - Data Fetching

    /// 获取用量数据（Claude + Codex 并发）
    func fetchUsage() {
        isLoading = true
        errorMessage = nil
        codexErrorMessage = nil
        lastAPIFetchTime = Date()

        // 每次刷新前先重新探测 Codex CLI 凭据文件（只读），使 CLI 登录/登出
        // 无需用户打开 Settings 即可在一个刷新周期内被感知。
        // `.accountChanged` 若因此触发，会在 handleAccountChanged 中被抑制以避免与本次请求重复。
        isSyncingCodexCLIState = true
        settings.refreshCodexCLIState()
        isSyncingCodexCLIState = false

        // 同上，每次刷新前重新探测 agy Keychain 凭据条目是否存在（只读属性探测，不读数据），
        // 使 Keychain 来源的启用/失效无需打开 Settings 即可被感知。
        // 返回值表示这次探测是否让"来源整体是否已配置"翻转（例如 agy 凭据消失导致自动撤回
        // opt-in）；翻转时下面必须 `force: true` 拉取，否则 `handleAccountChanged(.antigravity)`
        // 刚清空的数据会被 300s 客户端节流原样吞掉，让该 provider 空白最长 5 分钟。
        isSyncingAntigravityKeychainState = true
        let antigravityKeychainStateChanged = settings.refreshAntigravityKeychainState()
        isSyncingAntigravityKeychainState = false

        let fetchClaude = shouldFetchClaudeUsage
        let fetchCodex = shouldFetchCodexUsage
        let fetchAntigravity = shouldFetchAntigravityUsage

        if !fetchClaude {
            clearClaudeUsageState()
        }
        if !fetchCodex {
            clearCodexUsageState()
        }

        guard fetchClaude || fetchCodex || fetchAntigravity else {
            clearAntigravityUsageState()
            isLoading = false
            endRefreshAnimationWithMinimumDuration { }
            errorMessage = UsageError.noCredentials.localizedDescription
            return
        }

        let group = DispatchGroup()
        var codexResult: Result<CodexUsageData, Error>?
        var claudeResultsByAccount: [UUID: Result<UsageData, Error>] = [:]
        let claudeAccounts = settings.accounts.filter { $0.provider == .claude }

        if !fetchAntigravity {
            clearAntigravityUsageState()
        } else {
            // Antigravity 现在也进同一个 `group`——不是因为它需要和 Claude/Codex 互相等待
            // （每账户仍各自限流、各自即时发布，见 `fetchAntigravityOnly` 上的说明），而是为了让
            // 它的利用率能折算进下面 `group.notify` 里那一次性的 `monitoringUtilizations`
            // 字典，从而做到整个刷新周期只调用一次 `updateSmartMonitoringMode`
            // （`updateMonitoring: false`——见该方法的参数注释）。
            group.enter()
            fetchAntigravityOnly(force: antigravityKeychainStateChanged, updateMonitoring: false) {
                group.leave()
            }
        }

        // Claude 请求：遍历所有 Claude 账户，按 0.4s 间隔错开发起，降低 Cloudflare/限流风险
        if fetchClaude {
            for (index, account) in claudeAccounts.enumerated() {
                group.enter()
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.4) { [weak self] in
                    guard let self = self else {
                        group.leave()
                        return
                    }
                    self.claudeService(for: account).fetchUsage { result in
                        claudeResultsByAccount[account.id] = result
                        group.leave()
                    }
                }
            }
        }

        // Codex 请求（仅当有凭证时）
        if fetchCodex {
            group.enter()
            codexApiService.fetchUsage { result in
                codexResult = result
                if case .failure(let error) = result {
                    Logger.menuBar.info("Codex 请求失败（不影响主功能）: \(error.localizedDescription)")
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.isLoading = false
            self.endRefreshAnimationWithMinimumDuration { }

            var monitoringUtilizations: [ProviderType: Double] = [:]
            if fetchCodex {
                switch codexResult {
                case .success(let codex):
                    let previousCodexData = self.codexUsageData
                    self.codexUsageData = codex
                    self.codexErrorMessage = nil
                    if let utilization = self.monitoringUtilization(for: codex) {
                        monitoringUtilizations[.codex] = utilization
                    }

                    if self.settings.notificationsEnabled {
                        NotificationManager.shared.checkAndNotify(codexUsageData: codex, previousData: previousCodexData)
                    }

                    let newCodexResetsAt = codex.primary?.resetsAt
                    let codexResetChanged = self.hasResetTimeChanged(from: self.lastCodexResetsAt, to: newCodexResetsAt)
                    if codexResetChanged {
                        self.cancelCodexResetVerification()
                    } else if let resetsAt = newCodexResetsAt {
                        self.scheduleCodexResetVerification(resetsAt: resetsAt)
                    }
                    self.lastCodexResetsAt = newCodexResetsAt

                case .failure(let error):
                    self.codexErrorMessage = error.localizedDescription
                    self.clearCodexUsageState(clearError: false)

                case .none:
                    self.clearCodexUsageState()
                }
            } else {
                self.clearCodexUsageState()
            }

            // 处理 Claude 结果：逐账户合并，一个账户的错误不清除/隐藏其他账户的数据
            if fetchClaude {
                for account in claudeAccounts {
                    guard let result = claudeResultsByAccount[account.id] else { continue }
                    self.mergeClaudeResult(account: account, result: result)
                }

                // 多账户收敛为一个值（取最坏情况）供智能刷新间隔使用；轮询间隔是全局的，无法按账户区分
                if let maxUtilization = self.claudeUsageByAccount.values.map(\.percentage).max() {
                    monitoringUtilizations[.claude] = maxUtilization
                }

                self.rebuildClaudeSnapshots()
                self.assignFirstClaudeAccountState()
            }

            // Antigravity 折算进同一个字典——`fetchAntigravityOnly` 上面以 `updateMonitoring: false`
            // 调用，本身不会再触发一次 `updateSmartMonitoringMode`。
            if fetchAntigravity, let maxUtilization = self.antigravityUsageByAccount.values.compactMap(self.monitoringUtilization).max() {
                monitoringUtilizations[.antigravity] = maxUtilization
            }

            self.settings.updateSmartMonitoringMode(providerUtilizations: monitoringUtilizations)
        }
    }

    /// 合并单个账户的 Claude 拉取结果：成功则更新数据并清错误；失败则仅标记错误，
    /// 保留该账户上一次成功拉取的数据，使该行降级为"过期数据+错误"而非清空（错误隔离）
    /// - Note: `NotificationManager.checkAndNotify` 现在显式接收本次拉取的 `account.id`，
    ///   不再依赖内部的 `currentAccountId` 解析，确保后台（非当前选中）账户的
    ///   通知也能正确归因到实际拉取的账户。
    private func mergeClaudeResult(account: Account, result: Result<UsageData, Error>) {
        switch result {
        case .success(let data):
            let previousData = claudeUsageByAccount[account.id]
            claudeUsageByAccount[account.id] = data
            claudeErrorByAccount[account.id] = nil

            if settings.notificationsEnabled {
                NotificationManager.shared.checkAndNotify(usageData: data, previousData: previousData, accountId: account.id, accountDisplayName: account.displayName)
            }

            let newResetsAt = data.resetsAt
            let hasResetChanged = hasResetTimeChanged(from: lastResetsAtByAccount[account.id], to: newResetsAt)
            if hasResetChanged {
                cancelResetVerification(accountId: account.id)
            } else if let resetsAt = newResetsAt {
                scheduleResetVerification(account: account, resetsAt: resetsAt)
            }
            if let newResetsAt {
                lastResetsAtByAccount[account.id] = newResetsAt
            } else {
                lastResetsAtByAccount.removeValue(forKey: account.id)
            }

        case .failure(let error):
            claudeErrorByAccount[account.id] = error.localizedDescription
            Logger.menuBar.error("Claude API 请求失败 (\(account.displayName)): \(error.localizedDescription)")
        }
    }

    /// 仅刷新单个 Claude 账户并合并结果；供重置验证定时器使用，避免像调用全量 `fetchUsage()`
    /// 那样让 N 个账户 × 3 个验证定时器同时触发 N×3 次全量刷新，抵消 0.4s 错峰节流的限流缓解效果
    /// - Parameter account: 目标账户；若该账户已从 `settings.accounts` 中移除则跳过
    private func fetchClaudeAccount(_ account: Account) {
        guard settings.accounts.contains(where: { $0.id == account.id && $0.provider == .claude }) else { return }

        claudeService(for: account).fetchUsage { [weak self] result in
            guard let self = self else { return }
            self.mergeClaudeResult(account: account, result: result)

            // 注意：此为重置验证专用的定向轮询（3 个定时器 × N 个账户，30 秒内可能多次触发），
            // 不应调用 `updateSmartMonitoringMode`，否则会让 `unchangedCount` 被过快累加，
            // 导致智能轮询在用户可能刚变为活跃时被过早降级为 idle。
            self.rebuildClaudeSnapshots()
            self.assignFirstClaudeAccountState()
        }
    }

    /// 将 `settings.accounts` 中每个 Claude 账户的最新数据/错误映射为渲染用的快照，顺序与 `settings.accounts` 一致
    private func rebuildClaudeSnapshots() {
        claudeSnapshots = settings.accounts
            .filter { $0.provider == .claude }
            .map { account in
                let data = claudeUsageByAccount[account.id]
                return AccountUsageSnapshot(
                    accountId: account.id,
                    provider: .claude,
                    displayName: account.displayName,
                    color: account.color,
                    fiveHour: Self.windowUsage(from: data?.fiveHour, windowSeconds: Self.claudeFiveHourWindowSeconds),
                    sevenDay: Self.windowUsage(from: data?.sevenDay, windowSeconds: Self.claudeSevenDayWindowSeconds),
                    errorMessage: claudeErrorByAccount[account.id]
                )
            }
    }

    /// 将 `settings.antigravityAccounts` 中每个账户的最新数据/错误映射为渲染用的快照，
    /// 顺序与 `settings.antigravityAccounts` 一致，形状同 `rebuildClaudeSnapshots()`。
    /// - Important: 必须在**每个账户各自完成拉取时**调用（`mergeAntigravityResult` 内部），
    ///   而不是像 Claude 那样等一整轮 `DispatchGroup` 全部账户都完成后才调用一次——Antigravity
    ///   的 `fetchAntigravityOnly` 本来就是"每个账户各自限流、各自即时发布"，快照重建必须跟上
    ///   同一粒度，否则先完成的账户会在其它账户还在请求时被晾在旧快照里。
    private func rebuildAntigravitySnapshots() {
        antigravitySnapshots = AccountUsageSnapshot.antigravitySnapshots(
            from: antigravityUsageByAccount,
            accounts: settings.antigravityAccounts,
            errors: antigravityErrorByAccount
        )
    }

    /// 将 `UsageData.LimitData` 映射为 `WindowUsage`；Claude 的窗口时长是固定常量，直接写入而非留 nil
    /// （与 Codex 不同：Codex 的窗口时长数据驱动，应继续从 `CodexUsageData.LimitData` 读取）
    private static func windowUsage(from limit: UsageData.LimitData?, windowSeconds: TimeInterval) -> WindowUsage? {
        guard let limit else { return nil }
        return WindowUsage(percentage: limit.percentage, resetsAt: limit.resetsAt, windowSeconds: windowSeconds)
    }

    /// 将 `usageData`/`errorMessage`（向后兼容属性）赋值为 `settings.accounts` 中排在第一位的 Claude 账户的数据
    /// 保持 `MenuBarManager`、`MenuBarIconRenderer`、`UsageDetailView` 依赖这两个旧属性的代码路径编译期不变
    private func assignFirstClaudeAccountState() {
        guard let firstClaudeAccount = settings.accounts.first(where: { $0.provider == .claude }) else {
            usageData = nil
            errorMessage = nil
            return
        }
        usageData = claudeUsageByAccount[firstClaudeAccount.id]
        errorMessage = claudeErrorByAccount[firstClaudeAccount.id]
    }

    private func clearClaudeUsageState() {
        usageData = nil
        errorMessage = nil
        claudeUsageByAccount.removeAll()
        claudeErrorByAccount.removeAll()
        claudeSnapshots.removeAll()
        lastResetsAtByAccount.removeAll()
        for service in claudeServices.values {
            service.cancelAllRequests()
        }
        for accountId in claudeServices.keys {
            cancelResetVerification(accountId: accountId)
        }
    }

    private func clearCodexUsageState(clearError: Bool = true) {
        codexUsageData = nil
        if clearError {
            codexErrorMessage = nil
        }
        lastCodexResetsAt = nil
        cancelCodexResetVerification()
    }

    private func monitoringUtilization(for codex: CodexUsageData) -> Double? {
        [
            codex.primary?.percentage,
            codex.secondary?.percentage,
            codex.extraUsage?.percentage
        ]
        .compactMap { $0 }
        .max()
    }

    private func monitoringUtilization(for antigravity: AntigravityUsageData) -> Double? {
        antigravity.buckets.map(\.usagePercentage).max()
    }

    /// 遍历全部（去重后的）Antigravity 账户拉取；每个账户各自限流、各自记录错误，
    /// 且**每个账户完成时立即发布**，不等其它账户——与 `mergeClaudeResult` 的即时发布规则一致，
    /// 而不是像 Codex 单值那样等一次请求整体完成。智能监控的降级判断则相反，
    /// 要等全部账户都完成后一次性调用（见 `mergeAntigravityResult` 上的说明）。
    /// - Parameter completion: 全部账户完成后调用一次；仅 `handleAntigravityOnlyRefresh()`
    ///   用它来结束刷新动画，周期性 `fetchUsage()` 不传，动画收尾仍由
    ///   Claude/Codex 的主 `DispatchGroup` 负责。
    /// - Parameter updateMonitoring: 是否在本方法内部自己调用一次 `updateSmartMonitoringMode`。
    ///   周期性 `fetchUsage()` 传 `false`——它把 Antigravity 的最坏利用率折算进与 Claude/Codex
    ///   共用的同一个 `monitoringUtilizations` 字典，由主 `DispatchGroup.notify` 统一调用**一次**；
    ///   这里如果还各自再调用一次，`unchangedCount` 会在同一个刷新周期里被推进两次，把智能轮询
    ///   过早降级为 idle 的速度加倍，且这次多余调用读的是"上一轮遗留"的数据，即使本轮全部账户
    ///   都被节流跳过或失败也照样触发。除周期性 `fetchUsage()` 之外
    ///   的所有调用方（手动刷新、来源切换、账户变更）都是独立触发，保持默认 `true`。
    private func fetchAntigravityOnly(force: Bool = false, updateMonitoring: Bool = true, completion: (() -> Void)? = nil) {
        guard shouldFetchAntigravityUsage else {
            clearAntigravityUsageState()
            completion?()
            return
        }

        let accounts = antigravityAccountsToFetch
        guard !accounts.isEmpty else {
            clearAntigravityUsageState()
            completion?()
            return
        }

        let group = DispatchGroup()
        for account in accounts {
            // `.oauth` 账户自带 refresh token，来源不需要仲裁；`.keychain` 伪账户走 Keychain
            // 来源，且 `accountId` 传 nil（`AntigravityAPIService` 的 `.keychain` throttleKey
            // 恒定单账户，忽略 accountId）——两条路径各自独立，不受 `preferredAntigravitySource`
            // 影响。
            // `account.antigravitySource` 恒非 nil——`antigravityAccountsToFetch` 全部取自
            // `settings.antigravityAccounts`，按构造只包含 `provider == .antigravity` 的账户
            // （见 `Account.antigravitySource`）；万一出现 nil（不应发生），跳过而不是崩溃。
            guard let accountSource = account.antigravitySource else { continue }
            let accountId: UUID? = accountSource == .keychain ? nil : account.id
            // 不再有任何"允许这次读取弹窗"的标记——`antigravityAccountsToFetch` 已经把没有内存态
            // Keychain 凭据的伪账户整个过滤掉了，走到这里的 `.keychain` 账户必定
            // `antigravityTokenProvider.hasKeychainCredential == true`，`fetchUsage` 只会用这份
            // 内存凭据刷新 access token，绝不触碰钥匙串。
            group.enter()
            antigravityApiService.fetchUsage(source: accountSource, accountId: accountId, force: force) { [weak self] result in
                guard let self = self else {
                    group.leave()
                    return
                }
                self.mergeAntigravityResult(account: account, result: result)
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else {
                completion?()
                return
            }
            // 多账户收敛为一个值（取最坏情况）供智能刷新间隔使用，且只在全部账户完成后调用一次
            // ——绝不能像之前那样在每个账户各自的完成回调里各调用一次 `updateSmartMonitoringMode`，
            // 那样会让 `unchangedCount` 按账户数成倍累加，导致智能轮询过早降级为 idle
            // （见 `mergeClaudeResult`/`DataRefreshManager.swift:412` 的同一条注释）。
            if updateMonitoring, let maxUtilization = self.antigravityUsageByAccount.values.compactMap(self.monitoringUtilization).max() {
                self.settings.updateSmartMonitoringMode(providerUtilizations: [.antigravity: maxUtilization])
            }
            completion?()
        }
    }

    /// 合并单个账户的 Antigravity 拉取结果，成功即时发布，失败仅标记该账户错误
    /// （不清空该账户上一次成功拉取的数据，也不影响其他账户，即错误隔离）——
    /// 这一点现在渲染层也是成立的：`AccountUsageSnapshot.antigravitySnapshot` 会带着这份
    /// 保留下来的数据继续产出快照，而不是把整行丢弃。
    /// - Important: 不在这里调用 `updateSmartMonitoringMode`——那是 `fetchAntigravityOnly` 的
    ///   `group.notify` 在全部账户完成后才做的事。
    /// - Important: 无论成功还是失败都记录 `lastServingSource`——设置页展示"上次尝试走的是
    ///   哪个来源"不应该只在成功时才有值。
    private func mergeAntigravityResult(account: Account, result: Result<AntigravityUsageData, Error>) {
        let isKeychainAccount = (account.id == UserSettings.antigravityKeychainAccountId)
        antigravityLastServingSourceByAccount[account.id] = account.antigravitySource

        switch result {
        case .success(let data):
            antigravityUsageByAccount[account.id] = data
            antigravityErrorByAccount[account.id] = nil
            settings.recordAntigravityAccountError(nil, accountId: account.id)
            if isKeychainAccount {
                settings.recordAntigravityKeychainError(nil)
            }
            // 每次成功拉取都重新核验一次 Keychain 身份（而不是只在首次占位符阶段做一次）——
            // 否则 `agy logout && agy login <另一个账户>` 这种原地身份替换永远不会被发现，
            // App 会继续把用户从未同意过的身份的凭据发出去。
            if isKeychainAccount {
                resolveAntigravityKeychainIdentity(account: account)
            }
            rebuildAntigravitySnapshots()

        case .failure(let error):
            // 本地 300s 客户端节流跳过（`AntigravityFetchSkipped`）不是一次拉取失败——不应该被
            // 记成账户错误，否则活跃监控 60s 一次的心跳会有约 4/5 的周期把"刚拉过、数据仍新鲜"
            // 的账户误标成请求出错。不清空、不覆盖上一次成功/失败的状态，
            // 静默跳过即可。**与服务端真实 429（`UsageError.rateLimited`）严格区分**——后者必须
            // 继续走下面的可见错误路径。
            if case AntigravityFetchSkipped.clientThrottled = error {
                Logger.api.debug("Antigravity: 300s 节流内跳过，不计入账户错误 (\(account.displayName))")
                return
            }
            // 两个来源的失败都路由进 `AntigravitySourceError`，取它的弹出框短文案；OAuth 账户
            // （多账户场景下的多数情况）此前直接存 `error.localizedDescription`，拿不到短/长
            // 文案配对。
            let sourceError = AntigravitySourceError(source: account.antigravitySource ?? .oauth, underlying: error)
            let shortMessage = sourceError.errorDescription ?? error.localizedDescription
            antigravityErrorByAccount[account.id] = shortMessage
            settings.recordAntigravityAccountError(shortMessage, accountId: account.id)
            if isKeychainAccount {
                settings.recordAntigravityKeychainError(sourceError)
            }
            Logger.menuBar.error("Antigravity API 请求失败 (\(account.displayName)): \(error.localizedDescription)")
            // 仍需重建：`AccountUsageSnapshot.antigravitySnapshot` 对 `errorMessage != nil` 会带着
            // 该账户上一次成功拉取的数据（若有）继续产出一份快照（而不是返回 nil 让整行消失），
            // 与 `rebuildClaudeSnapshots` 的 Claude 行为一致——目的是避免 popover 行数/高度因为
            // 一次刷新失败而抖动。这里的 `rebuildAntigravitySnapshots()` 调用只是让新的
            // `errorMessage` 落进这份快照（供 `PopoverLayout.rowCount` 的 provider 级错误行判断
            // 和 hover 提示使用），并不是为了让快照消失。
            rebuildAntigravitySnapshots()
        }
    }

    /// Keychain 伪账户每次成功拉取后都重新解析一次 Google 身份（email + `sub`）写回
    /// `UserSettings`：
    /// 1. 首次解析用来使跨来源的按邮箱去重（`isAntigravityKeychainAccountRedundant`）真正生效；
    /// 2. 此后每次都重新核验，用来发现"钥匙串条目原地换了个 Google 身份"（`agy logout && agy
    ///    login <另一个账户>`），从而触发 `UserSettings.resolveAntigravityKeychainIdentity` 里的
    ///    自动撤回 opt-in（早先 `organizationName == "Antigravity"` 的占位符 guard 只允许成功解析
    ///    一次，之后再也不会核验，身份替换永远发现不了，因此改为每次都核验）。
    /// - Important: 这意味着 Keychain 来源现在每个刷新周期都会多打一次 tokeninfo 请求——这是
    ///   为了持续验证身份而接受的代价，只影响"Keychain 来源单独存在、未与任何 OAuth 账户去重"
    ///   的配置；一旦被判定为多余（去重掉），伪账户被整条移除，`antigravityAccountsToFetch`
    ///   直接不再包含它，这条路径也就完全不会被触发（见 `UserSettings.isAntigravityKeychainAccountRedundant`
    ///   的持久化身份设计）。
    private func resolveAntigravityKeychainIdentity(account: Account) {
        antigravityTokenProvider.resolveKeychainIdentity { [weak self] result in
            guard let self = self, case .success(let identity) = result else { return }
            self.settings.resolveAntigravityKeychainIdentity(email: identity.email, sub: identity.sub)
        }
    }

    private func clearAntigravityUsageState() {
        // 100% 的用户每次刷新都会跑到这里；未配置任何 Antigravity 来源时短路，
        // 避免白白触发两次 `@Published removeAll()`、一次 `NSLock` 往返，以及强制实例化
        // 惰性的 `antigravityApiService`（连带它的 `URLSession`）——对完全没有 Antigravity
        // 账户的用户，这一整套机器从不应该被唤醒。
        // - Note: 极端边缘情形——恰好在"刚移除最后一个账户"的这一次调用里短路，会跳过
        //   `cancelAllRequests()`，留一个正在进行中的请求自然完成；它写回的数据挂在一个已经
        //   不在 `settings.antigravityAccounts` 里的 id 下，不会被任何渲染路径读到，下一次账户
        //   变化时 `pruneAntigravityAccountState()` 会把它连同 token 缓存一起清掉。
        guard settings.hasAnyAntigravitySource else { return }
        antigravityUsageByAccount.removeAll()
        for accountId in antigravityErrorByAccount.keys {
            settings.clearAntigravityAccountError(accountId: accountId)
        }
        antigravityErrorByAccount.removeAll()
        antigravityLastServingSourceByAccount.removeAll()
        antigravitySnapshots.removeAll()
        antigravityApiService.cancelAllRequests()
    }

    /// 清理已不在 `settings.antigravityAccounts` 中的账户残留状态（账户被删除 / Keychain 伪账户被
    /// 撤下/判定为多余），并让其 access token 内存缓存失效——否则一个已被移除身份的、仍然有效的
    /// Google access token 会继续留在内存里直到自然过期。
    private func pruneAntigravityAccountState() {
        let currentIds = Set(settings.antigravityAccounts.map(\.id))
        // 失效集合必须来自"上一次观测到的账户 id 全集"，不能来自"曾经记录过用量/错误/来源数据的
        // 账户 id"——一个账户如果唯一的一次拉取只触发过 300s 节流跳过（`mergeAntigravityResult`
        // 对 `AntigravityFetchSkipped` 直接 `return`，从不写入下面任何一个字典），它被删除时
        // 就永远不会出现在旧的 staleIds 计算里，其 token 缓存也就永远不会失效。
        let staleIds = knownAntigravityAccountIds.subtracting(currentIds)

        for accountId in staleIds {
            if accountId == UserSettings.antigravityKeychainAccountId {
                antigravityTokenProvider.invalidate(source: .keychain, accountId: nil)
            } else {
                antigravityTokenProvider.invalidate(source: .oauth, accountId: accountId)
            }
            antigravityUsageByAccount.removeValue(forKey: accountId)
            antigravityErrorByAccount.removeValue(forKey: accountId)
            settings.clearAntigravityAccountError(accountId: accountId)
            antigravityLastServingSourceByAccount.removeValue(forKey: accountId)
        }

        knownAntigravityAccountIds = currentIds
        rebuildAntigravitySnapshots()
    }

    /// 开始数据刷新
    /// 立即获取一次数据并启动定时器
    func startRefreshing() {
        beginRefreshActivity()
        fetchUsage()
        restartTimer()

        #if DEBUG
        // 🧪 测试：确保图标显示徽章
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.objectWillChange.send()
        }
        #endif
    }

    /// 幂等启动数据刷新
    /// 若 `mainRefresh` 定时器已在运行，则不重复启动/不产生额外的一次性 fetch
    func startRefreshingIfNeeded() {
        guard !timerManager.isScheduled(TimerID.mainRefresh) else { return }
        startRefreshing()
    }

    /// 停止数据刷新
    func stopRefreshing() {
        timerManager.invalidate(TimerID.mainRefresh)
        endRefreshActivity()
    }

    /// 启动 Popover 刷新定时器
    /// 用于在 popover 打开时以 1 秒间隔触发 UI 更新
    /// - Parameter updateHandler: 每秒调用的更新闭包
    func startPopoverRefreshTimer(updateHandler: @escaping () -> Void) {
        timerManager.schedule(TimerID.popoverRefresh, interval: 1.0, repeats: true) {
            updateHandler()
        }
    }

    /// 停止 Popover 刷新定时器
    func stopPopoverRefreshTimer() {
        timerManager.invalidate(TimerID.popoverRefresh)
    }

    /// 重启刷新定时器
    /// 根据用户设置的刷新频率重新创建定时器
    private func restartTimer() {
        timerManager.invalidate(TimerID.mainRefresh)
        let interval = TimeInterval(settings.effectiveRefreshInterval)
        timerManager.schedule(TimerID.mainRefresh, interval: interval, repeats: true) { [weak self] in
            self?.fetchUsage()
        }
    }

    // MARK: - App Nap Prevention

    /// 开始后台活动声明，防止 macOS App Nap 冻结定时器
    private func beginRefreshActivity() {
        guard refreshActivity == nil else { return }
        refreshActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Periodic usage data refresh"
        )
    }

    /// 结束后台活动声明
    private func endRefreshActivity() {
        if let activity = refreshActivity {
            ProcessInfo.processInfo.endActivity(activity)
            refreshActivity = nil
        }
    }

    /// 注册系统唤醒监听
    /// 系统从睡眠唤醒后立即刷新数据，防止定时器在睡眠期间暂停导致长时间不更新
    private func setupWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Logger.menuBar.debug("系统从睡眠唤醒，立即刷新数据")
            // 延迟 3 秒等待网络恢复后再请求
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.fetchUsage()
            }
        }
    }

    // MARK: - Smart Refresh

    /// 打开Popover时的智能刷新
    /// 如果距离上次刷新 > 30秒，则立即刷新数据
    func refreshOnPopoverOpen() {
        let now = Date()

        // 用户打开详细界面，强制切换到活跃模式（1分钟刷新）
        if settings.refreshMode == .smart {
            let wasIdle = settings.currentMonitoringMode != .active
            settings.currentMonitoringMode = .active
            settings.unchangedCount = 0
            // 如果之前处于空闲模式，需要重启定时器以应用新间隔
            // 否则 updateSmartMonitoringMode 的 switchToActiveMode() 会因 guard 直接返回，导致定时器仍以旧间隔运行
            if wasIdle {
                restartTimer()
                Logger.menuBar.debug("用户打开界面，从空闲模式切换到活跃模式，重启定时器")
            } else {
                Logger.menuBar.debug("用户打开界面，已在活跃模式")
            }
        }

        // 如果距离上次刷新 < 30秒，跳过
        if let lastFetch = lastAPIFetchTime,
           now.timeIntervalSince(lastFetch) < 30 {
            return
        }

        fetchUsage()
    }

    /// 处理手动刷新
    /// 防抖机制：10秒内只能刷新一次
    func handleManualRefresh() {
        let now = Date()

        // 防抖检查：10秒内只能刷新一次
        if let lastManual = lastManualRefreshTime,
           now.timeIntervalSince(lastManual) < 10 {
            return
        }

        // 用户主动刷新，强制切换到活跃模式（1分钟刷新）
        if settings.refreshMode == .smart {
            let wasIdle = settings.currentMonitoringMode != .active
            settings.currentMonitoringMode = .active
            settings.unchangedCount = 0
            // 同 refreshOnPopoverOpen：若之前是空闲模式，需要重启定时器
            if wasIdle {
                restartTimer()
                Logger.menuBar.debug("用户主动刷新，从空闲模式切换到活跃模式，重启定时器")
            } else {
                Logger.menuBar.debug("用户主动刷新，已在活跃模式")
            }
        }

        // 更新状态
        lastManualRefreshTime = now
        refreshAnimationStartTime = now  // 记录动画开始时间
        refreshState.refreshingProvider = nil
        refreshState.isRefreshing = true

        // 设置防抖
        refreshState.canRefresh = false
        // 10秒后解除防抖
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.refreshState.canRefresh = true
        }

        // 触发刷新
        fetchUsage()
    }

    /// 仅刷新 Claude 数据（Claude 圆环点击触发）
    func handleClaudeOnlyRefresh() {
        guard shouldFetchClaudeUsage else { return }
        let now = Date()
        if let lastManual = lastManualRefreshTime,
           now.timeIntervalSince(lastManual) < 10 { return }
        if settings.refreshMode == .smart {
            let wasIdle = settings.currentMonitoringMode != .active
            settings.currentMonitoringMode = .active
            settings.unchangedCount = 0
            if wasIdle { restartTimer() }
        }
        lastManualRefreshTime = now
        refreshAnimationStartTime = now
        refreshState.refreshingProvider = .claude
        refreshState.isRefreshing = true
        refreshState.canRefresh = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.refreshState.canRefresh = true
        }
        fetchClaudeOnly()
    }

    /// 仅刷新 Codex 数据（Codex 圆环点击触发）
    func handleCodexOnlyRefresh() {
        guard shouldFetchCodexUsage else {
            clearCodexUsageState()
            return
        }
        let now = Date()
        if let lastManual = lastManualRefreshTime,
           now.timeIntervalSince(lastManual) < 10 { return }
        lastManualRefreshTime = now
        refreshAnimationStartTime = now
        refreshState.refreshingProvider = .codex
        refreshState.isRefreshing = true
        refreshState.canRefresh = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.refreshState.canRefresh = true
        }
        fetchCodexOnly()
    }

    /// 仅刷新 Antigravity 数据（Antigravity 圆环点击触发）
    func handleAntigravityOnlyRefresh() {
        guard shouldFetchAntigravityUsage else {
            clearAntigravityUsageState()
            return
        }
        let now = Date()
        if let lastManual = lastManualRefreshTime,
           now.timeIntervalSince(lastManual) < 10 { return }
        lastManualRefreshTime = now
        refreshAnimationStartTime = now
        refreshState.refreshingProvider = .antigravity
        refreshState.isRefreshing = true
        refreshState.canRefresh = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.refreshState.canRefresh = true
        }
        // 只有这里（用户手动点击）才需要结束刷新动画——周期性 `fetchUsage()` 的动画收尾
        // 仍由 Claude/Codex 的主 `DispatchGroup` 负责（此前这条路径设置了
        // `isRefreshing = true` 之后就没有任何回调把它设回 false，动画会一直转下去，
        // 因此这里显式补上收尾回调）。
        fetchAntigravityOnly(force: true) { [weak self] in
            self?.endRefreshAnimationWithMinimumDuration { }
        }
    }

    /// 仅刷新 Claude 数据：遍历所有 Claude 账户（同 `fetchUsage()` 的错开节奏），
    /// 单个账户失败仅标记该账户错误，不影响其他账户已拉取的数据
    private func fetchClaudeOnly() {
        guard shouldFetchClaudeUsage else {
            clearClaudeUsageState()
            return
        }

        let claudeAccounts = settings.accounts.filter { $0.provider == .claude }
        guard !claudeAccounts.isEmpty else {
            #if DEBUG
            // 调试模式下即使未配置任何真实账户，也应继续展示模拟数据（与 fetchUsage() 中
            // ClaudeAPIService.fetchUsage 的调试分支行为保持一致），而不是静默清空。
            if settings.debugModeEnabled {
                fetchClaudeDebugMockOnly()
                return
            }
            #endif
            clearClaudeUsageState()
            // 必须走与正常完成路径相同的动画收尾，否则 refreshState.isRefreshing 会永久卡在 true
            // （该 early-return 之前遗漏了这一步）
            endRefreshAnimationWithMinimumDuration { }
            return
        }

        isLoading = true
        errorMessage = nil
        lastAPIFetchTime = Date()

        let group = DispatchGroup()
        for (index, account) in claudeAccounts.enumerated() {
            group.enter()
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.4) { [weak self] in
                guard let self = self else {
                    group.leave()
                    return
                }
                self.claudeService(for: account).fetchUsage { [weak self] result in
                    guard let self = self else {
                        group.leave()
                        return
                    }
                    self.mergeClaudeResult(account: account, result: result)
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.isLoading = false
            self.endRefreshAnimationWithMinimumDuration { }

            if let maxUtilization = self.claudeUsageByAccount.values.map(\.percentage).max() {
                self.settings.updateSmartMonitoringMode(providerUtilizations: [.claude: maxUtilization])
            }

            self.rebuildClaudeSnapshots()
            self.assignFirstClaudeAccountState()
        }
    }

    #if DEBUG
    /// 调试模式下、且当前未配置任何 Claude 账户时使用：直接产出模拟数据，
    /// 保留旧版 `fetchClaudeOnly()`（改造前）在零账户场景下依然展示模拟数据的行为
    private func fetchClaudeDebugMockOnly() {
        isLoading = true
        errorMessage = nil
        lastAPIFetchTime = Date()

        ClaudeAPIService().fetchUsage { [weak self] result in
            guard let self = self else { return }
            self.isLoading = false
            self.endRefreshAnimationWithMinimumDuration { }

            if case .success(let data) = result {
                self.usageData = data
                self.errorMessage = nil
                self.settings.updateSmartMonitoringMode(providerUtilizations: [.claude: data.percentage])
            }
        }
    }
    #endif

    private func fetchCodexOnly() {
        guard shouldFetchCodexUsage else {
            clearCodexUsageState()
            return
        }
        isLoading = true
        codexErrorMessage = nil
        lastAPIFetchTime = Date()

        codexApiService.fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                self.endRefreshAnimationWithMinimumDuration { }

                if case .success(let data) = result {
                    let previousCodexData = self.codexUsageData
                    self.codexUsageData = data
                    self.codexErrorMessage = nil
                    if let utilization = self.monitoringUtilization(for: data) {
                        self.settings.updateSmartMonitoringMode(providerUtilizations: [.codex: utilization])
                    }
                    if self.settings.notificationsEnabled {
                        NotificationManager.shared.checkAndNotify(codexUsageData: data, previousData: previousCodexData)
                    }
                    let newCodexResetsAt = data.primary?.resetsAt
                    if self.hasResetTimeChanged(from: self.lastCodexResetsAt, to: newCodexResetsAt) {
                        self.cancelCodexResetVerification()
                    } else if let resetsAt = newCodexResetsAt {
                        self.scheduleCodexResetVerification(resetsAt: resetsAt)
                    }
                    self.lastCodexResetsAt = newCodexResetsAt
                } else if case .failure(let error) = result {
                    self.codexErrorMessage = error.localizedDescription
                    self.clearCodexUsageState(clearError: false)
                    Logger.menuBar.info("Codex 请求失败: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 账户颜色变更后仅从已缓存数据重建快照，不发起任何网络请求
    func handleAccountColorChanged() {
        rebuildClaudeSnapshots()
        rebuildAntigravitySnapshots()
    }

    /// 账户切换后只清理并刷新对应 Provider，避免跨账号 previousData 误判重置。
    /// 通知去重状态按账号隔离，切换账号时保留，删除账号时再由 UserSettings 精准清理。
    func handleAccountChanged(provider: ProviderType?) {
        switch provider {
        case .claude:
            errorMessage = nil
            pruneClaudeAccountState()
            if shouldFetchClaudeUsage {
                fetchClaudeOnly()
            } else {
                clearClaudeUsageState()
            }

        case .codex:
            clearCodexUsageState()
            if isSyncingCodexCLIState {
                // fetchUsage() 自身即将根据刚同步的 CLI 状态发起（或跳过）Codex 请求，
                // 这里不重复发起，避免同一刷新周期产生两次 Codex 请求。
                return
            }
            if shouldFetchCodexUsage {
                fetchCodexOnly()
            }

        case .antigravity:
            // 与 Codex 分支同一粒度：任何一个 Antigravity 账户变化（增删/切换/来源开关）
            // 都清空并对全部账户重新拉取一次——每账户各自 300s 节流，成本可忽略，
            // 不需要为此单独发明逐账户级的更细粒度处理。
            pruneAntigravityAccountState()
            clearAntigravityUsageState()
            if isSyncingAntigravityKeychainState {
                // `fetchUsage()` 自身即将根据刚同步出的、已经发生变化的 Keychain 来源状态发起
                // 一次 `force: true` 的 Antigravity 拉取（见 `fetchUsage()` 里
                // `antigravityKeychainStateChanged` 的说明），这里不重复发起，也不需要再补一次
                // 强制请求——上面的清空已经生效，紧接着那次强制拉取会替换掉它，不会像修复前那样
                // 依赖一次可能被 300s 节流吞掉的非强制请求。
                return
            }
            if shouldFetchAntigravityUsage {
                // `force: true`——刚清空的数据必须立刻有机会被替换，否则 300s 客户端节流会
                // 直接吞掉这次非强制请求（`UsageError.rateLimited`），让该 provider 空白最长
                // 5 分钟。
                fetchAntigravityOnly(force: true)
            }

        case .none:
            clearClaudeUsageState()
            clearCodexUsageState()
            clearAntigravityUsageState()
            NotificationManager.shared.resetAllNotificationStates()
            fetchUsage()
        }
    }

    /// 清理已不在 `settings.accounts` 中的 Claude 账户残留状态：取消其在途请求、
    /// 释放其 `ClaudeAPIService` 实例、清空其用量/错误/重置验证状态，并重建 `claudeSnapshots`
    private func pruneClaudeAccountState() {
        let currentIds = Set(settings.accounts.filter { $0.provider == .claude }.map(\.id))
        let staleIds = Set(claudeServices.keys).subtracting(currentIds)

        for accountId in staleIds {
            claudeServices[accountId]?.cancelAllRequests()
            claudeServices.removeValue(forKey: accountId)
            claudeUsageByAccount.removeValue(forKey: accountId)
            claudeErrorByAccount.removeValue(forKey: accountId)
            lastResetsAtByAccount.removeValue(forKey: accountId)
            cancelResetVerification(accountId: accountId)
        }

        rebuildClaudeSnapshots()
    }

    /// Codex 来源（CLI / Browser）切换后立即重新拉取，不经过手动刷新防抖
    func handleCodexSourceChanged() {
        clearCodexUsageState()
        if shouldFetchCodexUsage {
            fetchCodexOnly()
        }
    }

    /// Antigravity 偏好来源（Keychain / OAuth）切换后立即重新拉取，同 `handleCodexSourceChanged()`
    func handleAntigravitySourceChanged() {
        clearAntigravityUsageState()
        if shouldFetchAntigravityUsage {
            // 同上：非强制请求会被 300s 节流吞掉，让来源切换后空白最长 5 分钟。
            fetchAntigravityOnly(force: true)
        }
    }

    /// 结束刷新动画，确保至少显示最小时长
    /// - Parameter completion: 动画结束后的回调
    private func endRefreshAnimationWithMinimumDuration(completion: @escaping () -> Void) {
        guard let startTime = refreshAnimationStartTime else {
            // 没有记录开始时间，直接结束
            refreshState.isRefreshing = false
            refreshState.refreshingProvider = nil
            completion()
            return
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let remaining = minimumAnimationDuration - elapsed

        if remaining > 0 {
            // 动画时间不足，延迟剩余时间后再结束
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.refreshState.isRefreshing = false
                self?.refreshState.refreshingProvider = nil
                completion()
            }
        } else {
            // 动画时间已足够，直接结束
            refreshState.isRefreshing = false
            refreshState.refreshingProvider = nil
            completion()
        }

        // 清除开始时间记录
        refreshAnimationStartTime = nil
    }

    // MARK: - Reset Verification

    /// 检测重置时间是否发生变化
    /// - Parameters:
    ///   - oldTime: 上次的重置时间
    ///   - newTime: 新的重置时间
    /// - Returns: 如果重置时间发生了变化则返回 true
    private func hasResetTimeChanged(from oldTime: Date?, to newTime: Date?) -> Bool {
        // 如果两者都为 nil，没有变化
        if oldTime == nil && newTime == nil {
            return false
        }

        // 如果一个为 nil 另一个不为 nil，有变化
        if (oldTime == nil) != (newTime == nil) {
            return true
        }

        // 如果两者都不为 nil，比较时间值（允许1秒误差）
        if let old = oldTime, let new = newTime {
            return abs(old.timeIntervalSince(new)) > 1.0
        }

        return false
    }

    /// 取消指定账户的所有重置验证定时器
    /// - Parameter accountId: 目标账户 ID；定时器 ID 按账户拼接，避免账户 B 的重置取消账户 A 的验证
    private func cancelResetVerification(accountId: UUID) {
        timerManager.invalidate(resetVerifyTimerId(TimerID.resetVerify1, accountId: accountId))
        timerManager.invalidate(resetVerifyTimerId(TimerID.resetVerify2, accountId: accountId))
        timerManager.invalidate(resetVerifyTimerId(TimerID.resetVerify3, accountId: accountId))
    }

    /// 安排指定账户的重置时间验证
    /// 在重置时间过后的1秒、10秒、30秒分别触发一次刷新
    /// - Parameters:
    ///   - account: 目标账户
    ///   - resetsAt: 用量重置时间
    private func scheduleResetVerification(account: Account, resetsAt: Date) {
        let accountId = account.id
        // 清除该账户旧的验证定时器
        cancelResetVerification(accountId: accountId)

        // 计算距离重置时间的间隔
        let timeUntilReset = resetsAt.timeIntervalSinceNow

        // 只有重置时间在未来才安排验证
        guard timeUntilReset > 0 else {
            Logger.menuBar.debug("重置时间已过，跳过验证安排")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone.current
        Logger.menuBar.debug("安排重置验证 - 账户: \(accountId.uuidString) - 重置时间: \(formatter.string(from: resetsAt))")

        // 重置后1秒验证：仅刷新该账户，避免多账户 × 多验证定时器同时触发全量刷新风暴
        timerManager.schedule(resetVerifyTimerId(TimerID.resetVerify1, accountId: accountId), interval: timeUntilReset + 1, repeats: false) { [weak self] in
            Logger.menuBar.debug("重置验证 +1秒 - 开始刷新账户 \(accountId.uuidString)")
            self?.fetchClaudeAccount(account)
        }

        // 重置后10秒验证
        timerManager.schedule(resetVerifyTimerId(TimerID.resetVerify2, accountId: accountId), interval: timeUntilReset + 10, repeats: false) { [weak self] in
            Logger.menuBar.debug("重置验证 +10秒 - 开始刷新账户 \(accountId.uuidString)")
            self?.fetchClaudeAccount(account)
        }

        // 重置后30秒验证
        timerManager.schedule(resetVerifyTimerId(TimerID.resetVerify3, accountId: accountId), interval: timeUntilReset + 30, repeats: false) { [weak self] in
            Logger.menuBar.debug("重置验证 +30秒 - 开始刷新账户 \(accountId.uuidString)")
            self?.fetchClaudeAccount(account)
        }
    }

    // MARK: - Codex Reset Verification

    private func cancelCodexResetVerification() {
        timerManager.invalidate(TimerID.codexResetVerify1)
        timerManager.invalidate(TimerID.codexResetVerify2)
        timerManager.invalidate(TimerID.codexResetVerify3)
    }

    private func scheduleCodexResetVerification(resetsAt: Date) {
        cancelCodexResetVerification()

        let timeUntilReset = resetsAt.timeIntervalSinceNow
        guard timeUntilReset > 0 else {
            Logger.menuBar.debug("Codex 重置时间已过，跳过验证安排")
            return
        }

        timerManager.schedule(TimerID.codexResetVerify1, interval: timeUntilReset + 1, repeats: false) { [weak self] in
            Logger.menuBar.debug("Codex 重置验证 +1秒 - 开始刷新")
            self?.fetchUsage()
        }

        timerManager.schedule(TimerID.codexResetVerify2, interval: timeUntilReset + 10, repeats: false) { [weak self] in
            Logger.menuBar.debug("Codex 重置验证 +10秒 - 开始刷新")
            self?.fetchUsage()
        }

        timerManager.schedule(TimerID.codexResetVerify3, interval: timeUntilReset + 30, repeats: false) { [weak self] in
            Logger.menuBar.debug("Codex 重置验证 +30秒 - 开始刷新")
            self?.fetchUsage()
        }
    }

    // MARK: - Update Checking

    /// 安排每日更新检查
    private func scheduleDailyUpdateCheck() {
        #if DEBUG
        // 🧪 调试模式：检查是否启用模拟更新
        if settings.simulateUpdateAvailable {
            hasAvailableUpdate = true
            latestVersion = "2.0.0"
            Logger.menuBar.debug("模拟更新已启用，显示更新通知")
        } else {
            // 即使在 Debug 模式，也进行真实的更新检查
            checkForUpdatesInBackground()

            timerManager.schedule(TimerID.dailyUpdate, interval: 24 * 60 * 60, repeats: true) { [weak self] in
                self?.checkForUpdatesInBackground()
            }

            Logger.menuBar.info("Debug 模式：真实更新检查已启动")
        }
        #else
        // Release 模式：始终进行真实更新检查
        checkForUpdatesInBackground()

        // 每24小时检查一次
        timerManager.schedule(TimerID.dailyUpdate, interval: 24 * 60 * 60, repeats: true) { [weak self] in
            self?.checkForUpdatesInBackground()
        }

        Logger.menuBar.info("每日更新检查已启动")
        #endif
    }

    /// 后台静默检查更新（无UI提示）
    private func checkForUpdatesInBackground() {
        let now = Date()

        // 防止重复检查：距离上次检查 < 12小时则跳过
        if let lastCheck = lastUpdateCheckTime,
           now.timeIntervalSince(lastCheck) < 12 * 60 * 60 {
            return
        }

        lastUpdateCheckTime = now

        updateChecker.checkForUpdatesInBackground { [weak self] hasUpdate, version in
            DispatchQueue.main.async {
                guard let self = self else { return }

                self.hasAvailableUpdate = hasUpdate
                self.latestVersion = version
            }
        }
    }

    /// 用户手动检查更新
    func checkForUpdatesManually() {
        // 手动检查更新（会弹出对话框）
        updateChecker.checkForUpdates(manually: true)
    }

    // MARK: - Cleanup

    /// 清理所有资源
    func cleanup() {
        timerManager.invalidateAll()
        endRefreshActivity()
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    deinit {
        cleanup()
    }
}
