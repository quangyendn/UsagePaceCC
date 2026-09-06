//
//  AntigravitySignInCoordinator.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-09-06.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import AppKit
import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import OSLog

/// 应用内 Google 登录。
/// - Important: **不能**复用 `CodexWebLoginCoordinator` 的 WKWebView 方案 —— Google 会以
///   「this browser or app may not be secure」拒绝嵌入式 WebView 中的 OAuth。
/// - Important: agy 的 OAuth client 是 Desktop 类型，只接受回环地址重定向；
///   反转 client id 的自定义 scheme 是 iOS client 才有的能力，这里不可用。
///   因此由本地一次性 HTTP 监听器接收回调，`ASWebAuthenticationSession` 只负责呈现浏览器 UI，
///   监听器命中后由我们主动 `cancel()` 关掉它。
/// - Important: 每轮 `start()` 恰好交付一次终态结果——`hasFinished` 在任何可能的终态路径前都会
///   检查，且在我们主动 `cancel()` 呈现中的 `webAuthSession` 之前先置位一个独立的
///   `suppressCancelCallback` 标记，避免程序化 `cancel()` 触发的 `.canceledLogin` 覆盖掉真正的
///   登录结果。
final class AntigravitySignInCoordinator: NSObject, ObservableObject {

    enum SignInState: Equatable {
        case idle
        case listening          // 监听器已就绪，浏览器已打开
        case exchanging         // 拿到 code，正在换 token
        case resolvingAccount   // 正在查邮箱
        case success(email: String?)
        case failed(message: String)
    }

    /// 一轮成功登录交付给调用方的数据。`sub` 是 Google 账户的稳定数字 id，
    /// 用作 `Account.organizationId`；`email` 用作 `Account.organizationName`。
    typealias SignInResult = (refreshToken: String, email: String?, sub: String?)

    @Published private(set) var state: SignInState = .idle

    private static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"

    /// agy 请求的完整 scope 集合。
    /// 实现时先试最小集 `[openid, email, profile, aicode]`；若 `retrieveUserQuotaSummary`
    /// 返回 403，再退回这份完整集合。
    private static let fullScopes = [
        "openid", "email", "profile",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/aicode",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs"
    ]

    /// 最小 scope 集，用于日后收紧 scope 范围的实验；具体锁定结果见 `AntigravitySignInCoordinator.scopesInUse`
    private static let minimalScopes = ["openid", "email", "profile", "https://www.googleapis.com/auth/aicode"]

    /// 当前实际使用的 scope 集合。
    /// - Note: 验证 `retrieveUserQuotaSummary` 是否接受最小集，需要一次真实浏览器登录，这属于
    ///   运行期交互验证；先锁定为 agy 的完整集合，保证功能可用，人工验证后再收紧为 `minimalScopes`。
    static let scopesInUse = fullScopes

    private let loopbackServer = AntigravityLoopbackServer()
    private var webAuthSession: ASWebAuthenticationSession?

    /// 本轮 `start()` 是否已经交付过终态结果给调用方——保证 completion 只被调用一次。
    private var hasFinished = false
    /// 我们自己调用 `webAuthSession?.cancel()` 时置位，让呈现中 session 的完成回调忽略随之而来的
    /// `.canceledLogin`；这与 `hasFinished` 是两件事——`hasFinished` 标记"已经交付终态"，
    /// 这个标记只是"这次 cancel 是我们自己发起的，不代表用户手动取消"。
    private var suppressSessionCancelCallback = false
    /// 当前这轮 `start()` 的 completion；`cancel()` 需要它来交付一次终态结果。
    private var pendingCompletion: ((Result<SignInResult, Error>) -> Void)?
    /// `handleLoopbackReady` 里拼出的 `redirect_uri`，供 code exchange 复用（必须与授权请求
    /// 里使用的完全一致）。
    private var lastRedirectURI: URL?
    /// `handleLoopbackReady` 里拼出的授权 URL，供 `reopenBrowser()` 在同一轮监听器仍然存活时
    /// 重新呈现浏览器（`.listening` 期间 `pendingCompletion != nil`，重新调用 `start()` 只会被
    /// 拒绝且拒绝结果发到调用方这次传入的新 completion 上——原来那个 `pendingCompletion` 和
    /// `state` 都不会变，若不单独提供 `reopenBrowser()`，视图上的"重新打开登录页"会完全不起作用）。
    private var lastAuthURL: URL?

    // MARK: - Public

    /// 走完整个流程；成功时回调里带 refresh token、邮箱和 Google `sub`，由 `UserSettings` 负责落盘。
    func start(completion: @escaping (Result<SignInResult, Error>) -> Void) {
        // 上一轮 `start()` 还没交付终态结果就又被调用—— 拒绝这一轮而不是
        // 覆盖 `pendingCompletion`，否则第一轮的 completion 永远不会被交付，调用方悬挂。
        guard pendingCompletion == nil else {
            Logger.api.error("Antigravity sign-in: 已有一轮登录进行中，拒绝新的 start() 调用")
            DispatchQueue.main.async { completion(.failure(AntigravityAuthError.signInAlreadyInProgress)) }
            return
        }

        hasFinished = false
        suppressSessionCancelCallback = false
        pendingCompletion = completion

        guard let secrets = AntigravityOAuthSecrets.load() else {
            completeOnce(.failure(AntigravityAuthError.secretsUnavailable))
            return
        }
        let client = AntigravityOAuthClient(secrets: secrets)

        guard let verifier = Self.makeCodeVerifier() else {
            // SecRandomCopyBytes 失败 —— 绝不能退化成全零 verifier（那等于没有 PKCE）
            completeOnce(.failure(AntigravityAuthError.codeExchangeFailed("failed to generate PKCE verifier")))
            return
        }
        let challenge = Self.makeCodeChallenge(from: verifier)
        let expectedState = UUID().uuidString

        do {
            try loopbackServer.start(
                timeout: 180,
                closeMeMessage: L.SettingsAuth.antigravityBrowserPageBody,
                onReady: { [weak self] port in
                    self?.handleLoopbackReady(
                        port: port,
                        clientId: secrets.clientId,
                        challenge: challenge,
                        expectedState: expectedState
                    )
                },
                completion: { [weak self] result in
                    self?.handleLoopbackResult(result, client: client, verifier: verifier, expectedState: expectedState)
                }
            )
        } catch {
            completeOnce(.failure(error))
        }
    }

    func cancel() {
        guard !hasFinished else { return }
        dismissBrowserSession()
        // `loopbackServer.stop()` only re-triggers a terminal delivery while the loopback callback
        // itself hasn't already fired. Once it has (state == `.exchanging`/`.resolvingAccount`),
        // `stop()` on an already-finished server is a no-op and the in-flight code exchange keeps
        // running on its own, potentially calling `completeOnce(.success(...))` later and adding an
        // account with no visible UI — the round would survive its own cancellation.
        // Call `completeOnce` here directly so cancellation always wins; it is idempotent via
        // `hasFinished`, so if the loopback's own terminal delivery races ahead of us this is a no-op.
        loopbackServer.stop()
        completeOnce(.failure(AntigravityAuthError.signInCancelled))
    }

    /// 用户不小心关掉了浏览器标签页，希望"重新打开登录页"，但监听器/PKCE/state 仍然存活——
    /// 这里**不**发起新一轮 `start()`（那只会被 `pendingCompletion != nil` 拒绝），只是重新呈现
    /// 同一个已经生成好的授权 URL。只在 `.listening` 时有意义；其它状态下
    /// 调用方应改走 `start()` 开启全新一轮。
    func reopenBrowser() {
        guard state == .listening, let authURL = lastAuthURL else { return }
        presentBrowser(authURL: authURL)
    }

    // MARK: - Private — Loopback ready → present browser

    /// 端口已异步就绪（绝不能在 `start()` 返回后同步读取端口）；
    /// 到这里才能拼出 `redirect_uri` 并打开浏览器。
    private func handleLoopbackReady(port: UInt16, clientId: String, challenge: String, expectedState: String) {
        guard !hasFinished,
              let redirectURI = URL(string: "http://127.0.0.1:\(port)/callback"),
              let authURL = Self.makeAuthURL(clientId: clientId, redirectURI: redirectURI, state: expectedState, codeChallenge: challenge) else {
            // 失败时必须 `stop()` 监听器——否则它会占着已绑定的端口，直到 180s 硬超时才释放。
            loopbackServer.stop()
            completeOnce(.failure(AntigravityAuthError.loopbackFailed(underlying: nil)))
            return
        }

        lastRedirectURI = redirectURI
        lastAuthURL = authURL
        state = .listening
        presentBrowser(authURL: authURL)
    }

    // MARK: - Private — Presentation

    /// `ASWebAuthenticationSession` 只负责呈现浏览器 UI，callbackURLScheme 传 `nil`（回环地址不匹配任何
    /// 自定义 scheme），真正的回调由 `loopbackServer` 捕获；监听器命中后我们主动 dismiss 这个 session。
    /// 若呈现失败，回退到 `NSWorkspace.open` 打开系统默认浏览器。
    private func presentBrowser(authURL: URL) {
        // `reopenBrowser()` 调用这里时上一个 session 可能仍然挂着——若不先 dismiss 掉，旧
        // session 稍后触发的 `.canceledLogin` completion 会在 `suppressSessionCancelCallback`
        // 已经是 `false` 的情况下跑到下面的取消分支，把用户刚刚重新打开的这一轮杀掉。
        dismissBrowserSession()
        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: nil) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.suppressSessionCancelCallback {
                    // 我们自己触发的 cancel()（因为监听器已经命中，或调用方主动取消），
                    // 真正的结果已经/将要通过 loopback 的 completion 路径交付，这里必须忽略。
                    self.suppressSessionCancelCallback = false
                    return
                }
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    self.loopbackServer.stop()
                    self.completeOnce(.failure(AntigravityAuthError.signInCancelled))
                }
            }
        }
        session.presentationContextProvider = self
        // 每次都强制走完整凭据登录会带来全套用户名/密码/2FA，破坏"登录一次、长期刷新"的体验；
        // 让 Google 用其自有 cookie 记住会话。
        session.prefersEphemeralWebBrowserSession = false
        self.webAuthSession = session

        if !session.start() {
            Logger.api.error("Antigravity sign-in: ASWebAuthenticationSession 呈现失败，回退到默认浏览器")
            NSWorkspace.shared.open(authURL)
        }
    }

    /// 关掉当前呈现中的浏览器 session（若有），并抑制它随之而来的 `.canceledLogin` 完成回调。
    private func dismissBrowserSession() {
        guard let session = webAuthSession else { return }
        webAuthSession = nil
        suppressSessionCancelCallback = true
        session.cancel()
    }

    // MARK: - Private — Loopback → Exchange → Email

    private func handleLoopbackResult(
        _ result: Result<(code: String, state: String), Error>,
        client: AntigravityOAuthClient,
        verifier: String,
        expectedState: String
    ) {
        // Server delivers its completion on main (see AntigravityLoopbackServer.finish).
        dismissBrowserSession()

        switch result {
        case .failure(let error):
            completeOnce(.failure(error))

        case .success(let payload):
            guard payload.state == expectedState else {
                completeOnce(.failure(AntigravityAuthError.stateMismatch))
                return
            }

            state = .exchanging
            exchangeCode(payload.code, verifier: verifier, client: client)
        }
    }

    /// `redirect_uri` must exactly match the one used in the original authorization request
    /// (captured in `handleLoopbackReady` as `lastRedirectURI`); Google's token endpoint rejects a
    /// mismatch.
    private func exchangeCode(_ code: String, verifier: String, client: AntigravityOAuthClient) {
        guard let redirectURI = lastRedirectURI else {
            completeOnce(.failure(AntigravityAuthError.loopbackFailed(underlying: nil)))
            return
        }
        client.exchange(code: code, codeVerifier: verifier, redirectURI: redirectURI) { [weak self] exchangeResult in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch exchangeResult {
                case .failure(let error):
                    self.completeOnce(.failure(error))
                case .success(let tokens):
                    guard let refreshToken = tokens.refreshToken else {
                        self.completeOnce(.failure(AntigravityAuthError.codeExchangeFailed("missing refresh_token")))
                        return
                    }
                    self.state = .resolvingAccount
                    client.tokenInfo(accessToken: tokens.accessToken) { infoResult in
                        let info = try? infoResult.get()
                        DispatchQueue.main.async {
                            self.completeOnce(.success((refreshToken: refreshToken, email: info?.email, sub: info?.sub)))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Private — Terminal delivery

    /// 交付终态结果给调用方，保证在整个 `start()` 生命周期内恰好一次。
    private func completeOnce(_ result: Result<SignInResult, Error>) {
        guard !hasFinished else { return }
        hasFinished = true
        let completion = pendingCompletion
        pendingCompletion = nil

        switch result {
        case .success(let payload):
            state = .success(email: payload.email)
        case .failure(let error):
            state = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        completion?(result)
    }

    // MARK: - Private — PKCE

    /// 生成 PKCE code_verifier；显式检查 `SecRandomCopyBytes` 的返回状态——失败时绝不能退化成
    /// 全零/可预测的 verifier，那等于抹掉了 code 与本次会话的绑定。
    private static func makeCodeVerifier() -> String? {
        var bytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            Logger.api.error("Antigravity sign-in: SecRandomCopyBytes 失败 (OSStatus \(status, privacy: .public))")
            return nil
        }
        return base64URLEncode(Data(bytes))
    }

    private static func makeCodeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Private — Auth URL

    private static func makeAuthURL(clientId: String, redirectURI: URL, state: String, codeChallenge: String) -> URL? {
        var components = URLComponents(string: authURL)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopesInUse.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components?.url
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension AntigravitySignInCoordinator: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
