//
//  ClaudeUsageMonitorApp.swift
//  UsagePaceCC
//
//  Created by f-is-h on 2025-10-15.
//  Copyright © 2025 f-is-h. All rights reserved.
//

import SwiftUI
import Combine

/// UsagePaceCC 应用主入口
@main
struct ClaudeUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// 应用代理类
/// 负责应用生命周期管理、资源初始化和清理
class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties
    
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    
    /// 菜单栏管理器，负责所有菜单栏相关功能
    private var menuBarManager: MenuBarManager!
    
    /// 欢迎窗口，在首次启动时显示
    private var welcomeWindow: NSWindow?
    
    /// 用户设置实例
    private let settings = UserSettings.shared

    /// Combine 订阅集合，用于自动管理观察者生命周期
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Application Lifecycle
    
    /// 应用启动完成时调用
    /// 初始化菜单栏管理器，根据是否首次启动显示欢迎窗口或开始刷新数据
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 请求通知权限
        NotificationManager.shared.requestPermission()

        // 探测 Codex CLI 凭据文件（只读，见 D10），使仅配置了 CLI 的用户不会被误判为未登录。
        // - Important: 必须在 `MenuBarManager()` **之前**。`codexCLIDetected` 初值为 false，
        //   冷启动首探必定是 false→true 的跳变并发出 `.accountChanged`；若 MenuBarManager 已经
        //   订阅上了，就会先触发一次 `fetchCodexOnly()`，紧接着 `ensureRefreshingIfCredentialed()`
        //   再发一次 —— 而 `CodexAPIService.fetchUsage` 开头会 cancelAllRequests，后一次把前一次
        //   打断成 `URLError.cancelled`，启动瞬间闪一行错误。这里先探测，让冷启动只发一次请求。
        //   （`DataRefreshManager.isSyncingCodexCLIState` 只覆盖 `fetchUsage()` 内部的同步，管不到这里。）
        settings.refreshCodexCLIState()

        menuBarManager = MenuBarManager()

        if settings.isFirstLaunch || !settings.hasAnyValidCredentials {
            showWelcomeWindow()
        } else {
            menuBarManager.ensureRefreshingIfCredentialed()
        }

        // 使用 Combine 订阅通知，自动管理生命周期
        NotificationCenter.default.publisher(for: .openSettings)
            .sink { [weak self] notification in
                self?.openSettingsFromNotification(notification)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.settings.syncLaunchAtLoginStatus()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Private Methods
    
    /// 显示欢迎窗口
    /// 在首次启动或未配置认证信息时调用
    private func showWelcomeWindow() {
        NSApp.setActivationPolicy(.regular)

        let welcomeView = WelcomeView()
        let hostingController = NSHostingController(rootView: welcomeView)

        welcomeWindow = NSWindow(
            contentViewController: hostingController
        )
        welcomeWindow?.title = L.Window.welcomeTitle
        welcomeWindow?.styleMask = [.titled, .closable]
        welcomeWindow?.level = .floating

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = welcomeWindow?.frame ?? NSRect.zero
            let x = screenFrame.origin.x + (screenFrame.width - windowFrame.width) / 2
            let y = screenFrame.origin.y + (screenFrame.height - windowFrame.height) / 2
            welcomeWindow?.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // 使用 Combine 订阅窗口关闭通知
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: welcomeWindow)
            .sink { _ in
                NSApp.setActivationPolicy(.accessory)
            }
            .store(in: &cancellables)

        welcomeWindow?.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    /// 处理打开设置的通知
    /// 关闭欢迎窗口并根据认证配置状态启动刷新
    private func openSettingsFromNotification(_ notification: Notification) {
        welcomeWindow?.close()
        welcomeWindow = nil

        menuBarManager.ensureRefreshingIfCredentialed()
    }
    
    /// 应用即将退出时调用
    /// 清理定时器和窗口资源
    /// 注意：Combine 订阅会在 cancellables 被释放时自动清理
    func applicationWillTerminate(_ notification: Notification) {
        menuBarManager?.cleanup()
        welcomeWindow?.close()
        welcomeWindow = nil
        cancellables.removeAll()
    }
}
