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
    /// 更新检查器实例
    private let updateChecker = UpdateChecker()
    /// 定时器管理器
    private let timerManager = TimerManager()
    /// 用户设置实例
    private let settings = UserSettings.shared

    // MARK: - Published State

    /// Claude 用量数据（向后兼容属性：每次合并后从 `settings.accounts` 中排在第一位的 Claude 账户赋值）
    @Published var usageData: UsageData?
    /// 按账户 ID 索引的 Claude 用量数据（多账户全量拉取，phase 03/05 消费）
    @Published var claudeUsageByAccount: [UUID: UsageData] = [:]
    /// 按账户 ID 索引的 Claude 错误信息；某账户拉取失败不影响其他账户的数据
    @Published var claudeErrorByAccount: [UUID: String] = [:]
    /// 每账户一份用于渲染的用量快照，顺序与 `settings.accounts` 一致
    @Published var claudeSnapshots: [AccountUsageSnapshot] = []
    /// Codex 用量数据（nil 表示无 Codex 账号或拉取失败）
    @Published var codexUsageData: CodexUsageData?
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
    /// （见 Phase 04：一个刷新周期只应产生一次 Codex 请求）
    private var isSyncingCodexCLIState = false

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

        // 每次刷新前先重新探测 Codex CLI 凭据文件（只读，见 D10），使 CLI 登录/登出
        // 无需用户打开 Settings 即可在一个刷新周期内被感知（scout-01 候选 #1 修复的一部分）。
        // `.accountChanged` 若因此触发，会在 handleAccountChanged 中被抑制以避免与本次请求重复。
        isSyncingCodexCLIState = true
        settings.refreshCodexCLIState()
        isSyncingCodexCLIState = false

        let fetchClaude = shouldFetchClaudeUsage
        let fetchCodex = shouldFetchCodexUsage

        if !fetchClaude {
            clearClaudeUsageState()
        }
        if !fetchCodex {
            clearCodexUsageState()
        }

        guard fetchClaude || fetchCodex else {
            isLoading = false
            endRefreshAnimationWithMinimumDuration { }
            errorMessage = UsageError.noCredentials.localizedDescription
            return
        }

        let group = DispatchGroup()
        var codexResult: Result<CodexUsageData, Error>?
        var claudeResultsByAccount: [UUID: Result<UsageData, Error>] = [:]
        let claudeAccounts = settings.accounts.filter { $0.provider == .claude }

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

            self.settings.updateSmartMonitoringMode(providerUtilizations: monitoringUtilizations)
        }
    }

    /// 合并单个账户的 Claude 拉取结果：成功则更新数据并清错误；失败则仅标记错误，
    /// 保留该账户上一次成功拉取的数据，使该行降级为"过期数据+错误"而非清空（错误隔离）
    /// - Note: `NotificationManager.checkAndNotify` 目前仍通过 `currentAccountId` 内部解析账户 ID，
    ///   可能与实际拉取的 `account` 不一致；TODO(phase-05) 将改为显式传入 `accountId:` 参数
    private func mergeClaudeResult(account: Account, result: Result<UsageData, Error>) {
        switch result {
        case .success(let data):
            let previousData = claudeUsageByAccount[account.id]
            claudeUsageByAccount[account.id] = data
            claudeErrorByAccount[account.id] = nil

            if settings.notificationsEnabled {
                // TODO(phase-05): 传入显式 accountId，替代 NotificationManager 内部的 currentAccountId 解析
                NotificationManager.shared.checkAndNotify(usageData: data, previousData: previousData)
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

    /// 将 `UsageData.LimitData` 映射为 `WindowUsage`；Claude 的窗口时长是固定常量，直接写入而非留 nil
    /// （与 Codex 不同：Codex 的窗口时长数据驱动，应继续从 `CodexUsageData.LimitData` 读取）
    private static func windowUsage(from limit: UsageData.LimitData?, windowSeconds: TimeInterval) -> WindowUsage? {
        guard let limit else { return nil }
        return WindowUsage(percentage: limit.percentage, resetsAt: limit.resetsAt, windowSeconds: windowSeconds)
    }

    /// 将 `usageData`/`errorMessage`（向后兼容属性）赋值为 `settings.accounts` 中排在第一位的 Claude 账户的数据
    /// 保持 `MenuBarManager`、`MenuBarIconRenderer`（phase 05 前）、`UsageDetailView`（phase 03 前）编译期不变
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
    /// 若 `mainRefresh` 定时器已在运行，则不重复启动/不产生额外的一次性 fetch（见 Phase 04）
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
            // （见 code review：该 early-return 之前遗漏了这一步）
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

        case .none:
            clearClaudeUsageState()
            clearCodexUsageState()
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

    /// Codex 来源（CLI / Browser）切换后立即重新拉取，不经过手动刷新防抖（见 plan.md D9 / Phase 04）
    func handleCodexSourceChanged() {
        clearCodexUsageState()
        if shouldFetchCodexUsage {
            fetchCodexOnly()
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
