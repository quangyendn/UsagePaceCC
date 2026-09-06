//
//  WebLoginWindowManager.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-02-06.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import AppKit
import SwiftUI

/// Web 登录窗口管理单例
/// 负责创建、显示和关闭登录窗口
final class WebLoginWindowManager: NSObject {
    static let shared = WebLoginWindowManager()

    private var loginWindow: NSWindow?
    private var codexLoginWindow: NSWindow?
    private var antigravitySignInWindow: NSWindow?
    /// 与 `antigravitySignInWindow` 生命周期绑定的登录协调者——由本类持有（而非
    /// `AntigravitySignInView` 自己的 `@StateObject`），这样窗口被直接 `close()`/`orderOut`
    /// 时，`windowWillClose(_:)` 才有办法调用 `coordinator.cancel()`。
    private var antigravityCoordinator: AntigravitySignInCoordinator?

    private override init() {
        super.init()
    }

    /// 显示登录窗口
    /// - Parameter onAccountCreated: 账户创建成功后的回调
    func showLoginWindow(onAccountCreated: ((Account) -> Void)? = nil) {
        // 如果窗口已存在，直接前置
        if let window = loginWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let loginView = WebLoginView(onAccountCreated: onAccountCreated)
        let hostingView = NSHostingView(rootView: loginView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.title = L.WebLogin.windowTitle
        window.minSize = NSSize(width: 600, height: 500)
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating

        self.loginWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关闭登录窗口
    func closeLoginWindow() {
        loginWindow?.close()
        loginWindow = nil
    }

    /// 显示 Codex 登录窗口
    func showCodexLoginWindow(onAccountCreated: ((Account) -> Void)? = nil) {
        if let window = codexLoginWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let loginView = CodexWebLoginView(onAccountCreated: onAccountCreated)
        let hostingView = NSHostingView(rootView: loginView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.title = L.WebLogin.codexWindowTitle
        window.minSize = NSSize(width: 600, height: 500)
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating

        self.codexLoginWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关闭 Codex 登录窗口
    func closeCodexLoginWindow() {
        codexLoginWindow?.close()
        codexLoginWindow = nil
    }

    /// 显示 Antigravity 应用内 Google 登录窗口。
    /// - Parameter onSignedIn: 见 `AntigravitySignInView.onSignedIn` —— 同步返回账户是否
    ///   落盘成功（`addAntigravityOAuthAccount` 是否返回非 nil）。
    func showAntigravitySignInWindow(onSignedIn: ((AntigravitySignInCoordinator.SignInResult) -> Bool)? = nil) {
        if let window = antigravitySignInWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let coordinator = AntigravitySignInCoordinator()
        self.antigravityCoordinator = coordinator

        let signInView = AntigravitySignInView(
            coordinator: coordinator,
            onSignedIn: onSignedIn,
            onDismiss: { [weak self] in
                self?.closeAntigravitySignInWindow()
            }
        )
        let hostingView = NSHostingView(rootView: signInView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.title = L.SettingsAuth.antigravitySignInWindowTitle
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        // `.onDisappear` 在 `NSHostingView` 被直接 `close()`/`orderOut` 时不保证触发；
        // 这里显式兜底：无论窗口是通过 `closeAntigravitySignInWindow()` 关闭，还是用户点了
        // 标题栏的红绿灯，`windowWillClose(_:)` 都会取消协调者并清空引用。
        window.delegate = self

        self.antigravitySignInWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关闭 Antigravity 登录窗口
    func closeAntigravitySignInWindow() {
        antigravitySignInWindow?.delegate = nil
        antigravitySignInWindow?.close()
        antigravitySignInWindow = nil
        antigravityCoordinator?.cancel()
        antigravityCoordinator = nil
    }
}

// MARK: - NSWindowDelegate

extension WebLoginWindowManager: NSWindowDelegate {
    /// 兜底：用户直接点窗口的关闭按钮（而非走 `AntigravitySignInView` 里的 Cancel/Close 按钮）时，
    /// SwiftUI 的 `.onDisappear` 不保证触发，协调者的监听器/浏览器 session 会一直挂到 180s 硬超时，
    /// 期间若浏览器那端恰好完成了登录，还可能在没有任何确认 UI 的情况下悄悄新增一个账户。
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === antigravitySignInWindow else { return }
        antigravityCoordinator?.cancel()
        antigravityCoordinator = nil
        antigravitySignInWindow = nil
    }
}
