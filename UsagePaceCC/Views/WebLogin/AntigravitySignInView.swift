//
//  AntigravitySignInView.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-09-06.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import SwiftUI

/// Antigravity 应用内 Google 登录界面。
/// - Important: 与 `CodexWebLoginView` 不同——这里**没有** `WKWebView`。真正的浏览器是系统默认浏览器
///   （由 `AntigravitySignInCoordinator` 内部的 `ASWebAuthenticationSession` 呈现），这个视图只负责
///   在登录进行期间给用户一个「发生了什么」的说明，以及 Cancel / 完成后的收尾。
/// - Important: 绝不渲染授权 URL 的 `code`/`state`/PKCE verifier，也不提供任何「复制调试信息」
///   之类可能携带它们的功能。
struct AntigravitySignInView: View {
    // `coordinator` 由 `WebLoginWindowManager` 持有并注入（而非本视图自己的 `@StateObject`）——
    // 窗口被直接 `close()`/`orderOut` 时 SwiftUI 不保证对宿主在 `NSHostingView` 里的视图触发
    // `.onDisappear`，若 coordinator 仅活在视图自己的状态里就没有任何人能在那种情况下调用
    // `cancel()`：监听器会一直占用端口直到 180s 硬超时，且用完成的浏览器登录可能在无任何确认
    // UI 的情况下悄悄新增一个账户。窗口管理器改用
    // `NSWindowDelegate.windowWillClose` 兜底调用 `coordinator.cancel()`。
    @ObservedObject private var coordinator: AntigravitySignInCoordinator

    /// 登录成功后的落盘回调：调用方（`AuthSettingsView`）负责调用
    /// `UserSettings.addAntigravityOAuthAccount(refreshToken:email:sub:)` 并**同步**返回是否成功——
    /// 该方法在 email/sub 均缺失时返回 nil（身份未确认），这里必须能区分「浏览器登录成功」
    /// 和「账户落盘成功」两件事，不能把前者误当成后者展示给用户。
    var onSignedIn: ((AntigravitySignInCoordinator.SignInResult) -> Bool)?
    /// 窗口整体关闭回调（Cancel / Close 按钮），由 `WebLoginWindowManager` 提供
    var onDismiss: (() -> Void)?

    @State private var hasStarted = false
    /// 浏览器登录本身成功，但 `onSignedIn` 落盘失败（`addAntigravityOAuthAccount` 返回 nil）
    @State private var identityUnconfirmed = false

    init(
        coordinator: AntigravitySignInCoordinator,
        onSignedIn: ((AntigravitySignInCoordinator.SignInResult) -> Bool)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.onSignedIn = onSignedIn
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 登录前的说明：Google 同意页会显示 Antigravity 的名字而非本 App，
            // 不解释清楚会被误认为钓鱼页面。
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                Text(L.SettingsAuth.antigravitySignInExplainer)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statusBody

            Spacer()

            HStack {
                Spacer()
                footerButtons
            }
        }
        .padding(20)
        .frame(width: 420, height: 260)
        .onAppear { startIfNeeded() }
        .onDisappear { coordinator.cancel() }
        .onChange(of: coordinator.state) { newState in
            // 只有「浏览器登录成功 + 账户落盘也成功」才自动关闭窗口；身份未确认时
            // （`identityUnconfirmed`）必须停下来让用户看到这句话，而不是一闪而过。
            if case .success = newState, !identityUnconfirmed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    onDismiss?()
                }
            }
        }
    }

    // MARK: - Status body

    @ViewBuilder
    private var statusBody: some View {
        if identityUnconfirmed {
            statusRow(icon: "exclamationmark.triangle.fill", iconColor: .orange, text: L.SettingsAuth.antigravitySignInIdentityUnconfirmed, showSpinner: false)
        } else {
            switch coordinator.state {
            case .idle:
                statusRow(icon: "arrow.triangle.2.circlepath", iconColor: .secondary, text: L.SettingsAuth.antigravitySignInWaiting, showSpinner: true)

            case .listening:
                VStack(alignment: .leading, spacing: 6) {
                    statusRow(icon: "safari", iconColor: .blue, text: L.SettingsAuth.antigravitySignInWaiting, showSpinner: true)
                    // 这一轮登录仍在进行（监听器/PKCE/state 都还存活），`coordinator.start()`
                    // 会因为 `pendingCompletion != nil` 直接拒绝——必须重新呈现同一轮的授权 URL，
                    // 而不是尝试开启新一轮。
                    Button(action: { coordinator.reopenBrowser() }) {
                        Text(L.SettingsAuth.antigravitySignInReopen)
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                }

            case .exchanging:
                statusRow(icon: "arrow.triangle.2.circlepath", iconColor: .blue, text: L.SettingsAuth.antigravitySignInExchanging, showSpinner: true)

            case .resolvingAccount:
                statusRow(icon: "person.crop.circle.badge.checkmark", iconColor: .blue, text: L.SettingsAuth.antigravitySignInResolving, showSpinner: true)

            case .success(let email):
                statusRow(
                    icon: "checkmark.circle.fill",
                    iconColor: .green,
                    text: email.map { L.SettingsAuth.antigravitySignInSuccess($0) } ?? L.SettingsAuth.antigravitySignInSuccessNoEmail,
                    showSpinner: false
                )

            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    statusRow(icon: "exclamationmark.triangle.fill", iconColor: .red, text: message, showSpinner: false)
                    Button(action: { startIfNeeded(force: true) }) {
                        Text(L.SettingsAuth.antigravitySignInReopen)
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private func statusRow(icon: String, iconColor: Color, text: String, showSpinner: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .font(.body)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if showSpinner {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerButtons: some View {
        if identityUnconfirmed {
            Button(action: { onDismiss?() }) {
                Text(L.SettingsAuth.antigravitySignInClose)
            }
            .buttonStyle(.bordered)
        } else {
            switch coordinator.state {
            case .idle, .listening, .exchanging, .resolvingAccount:
                Button(action: {
                    coordinator.cancel()
                    onDismiss?()
                }) {
                    Text(L.SettingsAuth.antigravitySignInCancel)
                }
                .buttonStyle(.bordered)

            case .success:
                Button(action: { onDismiss?() }) {
                    Text(L.SettingsAuth.antigravitySignInClose)
                }
                .buttonStyle(.borderedProminent)

            case .failed:
                Button(action: { onDismiss?() }) {
                    Text(L.SettingsAuth.antigravitySignInClose)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Start

    /// 启动一轮登录。`force` 用于「重新打开登录页」——`AntigravitySignInCoordinator.start()`
    /// 在上一轮还没交付终态结果时会拒绝新的一轮（`.signInAlreadyInProgress`），这里只在
    /// 首次出现（`hasStarted == false`）或用户显式点了「重新打开」/「重试」时才调用，
    /// 不会在视图重绘时意外并发调用 `start()`。
    private func startIfNeeded(force: Bool = false) {
        guard force || !hasStarted else { return }
        hasStarted = true
        identityUnconfirmed = false
        coordinator.start { result in
            switch result {
            case .success(let signInResult):
                let confirmed = onSignedIn?(signInResult) ?? true
                if !confirmed {
                    identityUnconfirmed = true
                }
            case .failure:
                // 失败状态已经通过 `coordinator.state` 的 `.failed(message:)` 反映到 UI，
                // 这里无需额外处理——`AntigravitySignInCoordinator.completeOnce` 已经把
                // `LocalizedError.errorDescription` 映射进 state 了。
                break
            }
        }
    }
}
