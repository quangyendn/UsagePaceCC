//
//  AntigravityTokenProvider.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-09-06.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import Foundation

/// 屏蔽来源差异：上层只管要一个能用的 access_token。
/// - Important: `AntigravityAPIService` 不知道来源这回事；来源判定全部收敛在这里。
/// - Important: 本类型的方法从调用方线程（可能是主线程）和 `DispatchQueue.global` 两侧都会被调用
///   （见 `fetchFromKeychain`），而项目把 `SWIFT_DEFAULT_ACTOR_ISOLATION` 设成了 `MainActor`。
///   标成 `nonisolated` 让这个类型真正脱离 MainActor 隐式隔离，配合 `NSLock` 保护的 `cache`
///   做到线程安全（对照 `CodexCLIAuthReader` 的 `nonisolated enum` 先例）。
/// `@unchecked Sendable`: `cache` is guarded by `cacheLock` (`NSLock`); `loadOAuthRefreshToken` /
/// `persistOAuthRefreshToken` are `let`, injected once at `init` and never mutated afterwards, so
/// reading them from any thread is race-free by construction. This is a manually-verified
/// invariant, not something the compiler can check, hence `@unchecked` rather than plain `Sendable`.
nonisolated final class AntigravityTokenProvider: @unchecked Sendable {

    /// 内存缓存条目
    private struct CacheEntry {
        let accessToken: String
        let expiry: Date
    }

    /// 全 App 唯一实例——`connectKeychain(_:)` 写入的内存态 Keychain 凭据必须和
    /// `DataRefreshManager` 周期性拉取读到的是同一份状态，否则 Auth 页的 Connect 按钮和后台
    /// 拉取各自持有一份互不相通的"是否已连接"记忆，形同没有实现。`AuthSettingsView` 与
    /// `DataRefreshManager` 都通过这个单例访问。
    /// 两个钩子闭包会从任意线程被同步调用（`fetchFromOAuth` 从 `URLSession` 后台完成回调线程
    /// 直接读 `loadOAuthRefreshToken`，`resolveKeychainIdentity`/`fetchFromKeychain` 也可能从
    /// 后台队列调用），而 `UserSettings` 的方法在本项目 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
    /// 下隐式是 MainActor-isolated 的——`MainActor.assumeIsolated` 只是把"已知在主线程上、只是
    /// 编译器推断不出来"这件事显式标注给类型系统，真正的隔离切换仍然是下面 `Thread.isMainThread`
    /// 判断 + `DispatchQueue.main.sync` 完成的（同步桥接，因为这两个钩子的调用方需要立刻拿到
    /// 返回值/确保写入已完成，不能 `await`）。
    static let shared = AntigravityTokenProvider(
        loadOAuthRefreshToken: { accountId in
            AntigravityTokenProvider.callOnMain { UserSettings.shared.antigravityOAuthRefreshToken(accountId: accountId) }
        },
        persistOAuthRefreshToken: { accountId, refreshToken in
            AntigravityTokenProvider.callOnMain { UserSettings.shared.persistAntigravityOAuthRefreshToken(accountId: accountId, refreshToken: refreshToken) }
        }
    )

    /// 同步桥接到主线程：已经在主线程时直接执行（避免 `DispatchQueue.main.sync` 自死锁），
    /// 否则同步跳到主队列执行并等待结果。`MainActor.assumeIsolated` 让类型系统接受"这段代码
    /// 确实在主线程上运行"这一运行期事实，而不必把调用方一路改成 `async`（两个钩子的调用方都需要
    /// 立即拿到返回值 / 确保写入落地后再继续）。
    private static func callOnMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        var result: T!
        DispatchQueue.main.sync {
            result = MainActor.assumeIsolated(body)
        }
        return result
    }

    /// `.keychain` 恒定单账户；`.oauth` 按账户 id 各自缓存。用非 Optional 的 `AntigravityTokenKey`
    /// 而不是 `UUID?` 做键 —— 否则 `.oauth` 且 `accountId == nil` 会退化成与 `.keychain` 相同的
    /// `nil` 键，导致跨来源共享同一份 token 缓存。
    private var cache: [AntigravityTokenKey: CacheEntry] = [:]
    private let cacheLock = NSLock()

    /// **Keychain 来源**的凭据，只在 `connectKeychain(_:)`（用户点击 Connect/Reconnect 的直接
    /// 结果）成功后写入，进程生命周期内常驻——绝不落盘，也绝不因为
    /// `invalidate(source: .keychain, ...)`（账户被判定多余/移除）被清空：那只清空短期 access
    /// token 缓存，这份 refresh token 之所以还留着，正是为了让同一次启动内的后续拉取不需要
    /// 用户重复点击 Connect（"每次 App 启动点一次 Connect"是刻意付出的代价，换来的是绝不在
    /// 非用户手势路径弹出 ACL 授权框）。
    /// 由 `cacheLock` 保护，与 `cache` 共用同一把锁。
    private var keychainCredential: AntigravityCredential?

    /// 是否已经有一份可用的 Keychain 内存凭据——供 `UserSettings`/`AuthSettingsView` 判断
    /// 是否需要展示 Connect/Reconnect 而不是发起一次静默拉取。
    var hasKeychainCredential: Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return keychainCredential != nil
    }

    /// `.oauth` 账户的 refresh token 读取钩子；绑定到 `KeychainManager` / `Account.sessionKey`。
    /// nil 表示尚未接入持久化（此阶段允许，调用会得到 `.secretsUnavailable`）。
    /// 用 `let` 而非 `var`——本类型的方法会从 `URLSession` 后台完成回调线程读取这个闭包，若允许
    /// 运行期从主线程改写就是一次没有锁保护的数据竞争；构造之后只读，由
    /// 调用方在 `init` 时一次性注入。
    let loadOAuthRefreshToken: ((UUID) -> String?)?

    /// `.oauth` 刷新后（若 Google 轮换了 refresh_token）持久化钩子。同上，`let` 且只在 `init` 注入。
    /// 调用点（`fetchFromOAuth`）会先跳回主队列再执行这个闭包 —— 这个闭包绑定到
    /// `KeychainManager`，在本项目 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 下 `KeychainManager`
    /// 隐式是 MainActor-isolated 的普通 class，从后台线程直接调用会是一次隔离违规。
    let persistOAuthRefreshToken: ((UUID, String) -> Void)?

    /// 用 `let` 而非 `lazy var`——`lazy var` 的初始化不是线程安全的，本类型的方法会从多个队列
    /// 并发调用，一个 racy 的一次性初始化在这里是真实的数据竞争。
    private let oauthClient: AntigravityOAuthClient? = AntigravityOAuthSecrets.load().map { AntigravityOAuthClient(secrets: $0) }

    /// - Parameters:
    ///   - loadOAuthRefreshToken: `.oauth` 读取钩子；默认 nil（此阶段调用会得到 `.secretsUnavailable`）。
    ///   - persistOAuthRefreshToken: `.oauth` 刷新后持久化钩子；默认 nil。
    init(
        loadOAuthRefreshToken: ((UUID) -> String?)? = nil,
        persistOAuthRefreshToken: ((UUID, String) -> Void)? = nil
    ) {
        self.loadOAuthRefreshToken = loadOAuthRefreshToken
        self.persistOAuthRefreshToken = persistOAuthRefreshToken
    }

    // MARK: - Public — Keychain connect (user-gesture only)

    /// **全 App 唯一**调用 `AntigravityCredentialStore.read()` 的地方。只应该被 Auth 页的
    /// Connect / Reconnect 按钮点击直接调用——绝不能被定时器轮询、启动探测或
    /// `.accountChanged` 广播触发（此前曾试图用一次性标记 + `LAContext` 守卫在"轮询路径"上
    /// 间接放行/拦截这次读取，后来去掉了这个机制，因为
    /// 1) `LAContext.interactionNotAllowed` 对 `agy` 写入的 Legacy keychain 条目已被证明无效，
    /// 2) 那个一次性标记本身可能在从未被消费的情况下一直armed，直到某次不相关的轮询消费它，
    ///    在与本次用户操作无关的时间点弹出系统对话框）。
    /// 成功后把凭据整份缓存进内存（`keychainCredential`），供后续 `accessToken(source: .keychain, ...)`
    /// 调用直接复用/按其刷新 access token，不再触碰钥匙串——这是用户在本次启动内唯一需要点
    /// Connect 的一次。
    func connectKeychain(completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let credential = try AntigravityCredentialStore.read()
                self.cacheLock.lock()
                self.keychainCredential = credential
                self.cacheLock.unlock()
                if !credential.needsRefresh, let expiry = credential.expiry {
                    self.store(credential.accessToken, expiry: expiry, for: .keychain)
                }
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Public

    /// 取一个有效 access_token。
    /// - Parameter source: `.keychain` 时忽略 `accountId`（agy 恒定单账户）。
    /// - Parameter accountId: `.oauth` 时必填，决定用哪个账户的 refresh token。
    /// - Note: 回调统一在主线程交付，与其它路径（缓存命中 / 节流拒绝等）保持一致的调用约定，
    ///   方便调用方不必自己再判断当前队列。
    /// - Important: `.keychain` 分支**绝不**触碰 `AntigravityCredentialStore`——只消费
    ///   `connectKeychain(_:)` 此前写入内存的 `keychainCredential`。没有这份内存凭据时（尚未
    ///   点过 Connect，或上一次 Connect 失败）直接以 `.keychainNotConnected` 失败，而不是静默去
    ///   读一次钥匙串。
    func accessToken(source: AntigravitySource, accountId: UUID?, completion: @escaping (Result<String, Error>) -> Void) {
        let key: AntigravityTokenKey
        switch source {
        case .keychain:
            key = .keychain
        case .oauth:
            guard let accountId = accountId else {
                deliverOnMain(.failure(AntigravityAuthError.noAccessToken), completion)
                return
            }
            key = .oauth(accountId)
        }

        if let cached = cachedToken(for: key) {
            deliverOnMain(.success(cached), completion)
            return
        }

        switch key {
        case .keychain:
            fetchFromKeychain(completion: completion)
        case .oauth(let accountId):
            fetchFromOAuth(accountId: accountId, completion: completion)
        }
    }

    /// 清掉某账户的内存缓存（退出登录 / 切换来源时调用）。
    /// - Important: 显式传 `source` 而不是靠 `accountId == nil` 推断 —— `accountId.map { .oauth($0) }
    ///   ?? .keychain` 会让「`source == .oauth` 但 `accountId` 意外为 nil」的调用悄悄退化成清掉
    ///   `.keychain` 缓存，而不是报错（与上面 token key 用非 Optional 枚举避免的同一个坑）。`.oauth` 缺 `accountId`
    ///   时直接忽略调用（没有对应的缓存条目可清），而不是清错键。
    func invalidate(source: AntigravitySource, accountId: UUID?) {
        let key: AntigravityTokenKey
        switch source {
        case .keychain:
            key = .keychain
        case .oauth:
            guard let accountId = accountId else { return }
            key = .oauth(accountId)
        }
        cacheLock.lock()
        cache.removeValue(forKey: key)
        cacheLock.unlock()
    }

    /// 解析 **Keychain 来源** 凭据对应的 Google 身份（email + `sub`），供 `UserSettings` 做跨来源
    /// 邮箱去重。
    /// - Important: 只应在 Keychain 数据已经被合法读取之后调用（即 opt-in 之后的一次成功
    ///   `fetchUsage`）——本方法会再拿一次 `.keychain` 的 access_token（命中内存缓存时不重复
    ///   触发 ACL 弹窗，缓存未命中时走与 `fetchUsage` 完全相同的刷新路径），然后打一次
    ///   tokeninfo 端点，不额外读取 Keychain 数据。
    func resolveKeychainIdentity(completion: @escaping (Result<(email: String?, sub: String?), Error>) -> Void) {
        guard let client = oauthClient else {
            DispatchQueue.main.async { completion(.failure(AntigravityAuthError.secretsUnavailable)) }
            return
        }
        accessToken(source: .keychain, accountId: nil) { result in
            switch result {
            case .failure(let error):
                // `accessToken` 的 completion 本身恒在主线程交付（见类型文档），这里仍显式跳一次
                // `DispatchQueue.main.async`——不是因为不这样做会有线程问题，而是让这个失败分支
                // 在写法上和下面 `tokenInfo` 的两个出口（:133-140）保持同一种"看得出来"的一致性，
                // 不依赖读者去反查 `accessToken` 内部每条路径是否都走了 `deliverOnMain`。
                DispatchQueue.main.async { completion(.failure(error)) }
            case .success(let token):
                client.tokenInfo(accessToken: token) { infoResult in
                    DispatchQueue.main.async {
                        switch infoResult {
                        case .success(let info):
                            completion(.success((email: info.email, sub: info.sub)))
                        case .failure(let error):
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Private — Cache

    private func cachedToken(for key: AntigravityTokenKey) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = cache[key], entry.expiry > Date().addingTimeInterval(60) else {
            return nil
        }
        return entry.accessToken
    }

    private func store(_ token: String, expiry: Date, for key: AntigravityTokenKey) {
        cacheLock.lock()
        cache[key] = CacheEntry(accessToken: token, expiry: expiry)
        cacheLock.unlock()
    }

    private func deliverOnMain(_ result: Result<String, Error>, _ completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    // MARK: - Private — Source A

    /// `.keychain`：**不读钥匙串**——只消费 `connectKeychain(_:)` 留在内存里的凭据，过期则用它的
    /// refresh_token 刷新（新 access_token 只存内存），**丢弃**响应里可能带的 rotated
    /// refresh_token —— 绝不回写 agy 自己的钥匙串条目，也绝不用刷新后的新 refresh_token 更新
    /// `keychainCredential`（没有必要——agy 自己的钥匙串条目才是权威来源，我们只是不重复读它）。
    private func fetchFromKeychain(completion: @escaping (Result<String, Error>) -> Void) {
        cacheLock.lock()
        let credential = keychainCredential
        cacheLock.unlock()

        guard let credential else {
            // 从未成功 `connectKeychain(_:)` 过，或者上一次失败了——绝不能退回去读一次钥匙串，
            // 直接报"尚未连接"，由调用方（`DataRefreshManager`/UI）引导用户去点 Connect。
            deliverOnMain(.failure(AntigravityAuthError.keychainNotConnected), completion)
            return
        }

        if !credential.needsRefresh, let expiry = credential.expiry {
            store(credential.accessToken, expiry: expiry, for: .keychain)
            deliverOnMain(.success(credential.accessToken), completion)
            return
        }

        guard let client = oauthClient else {
            if let expiry = credential.expiry {
                deliverOnMain(.failure(AntigravityAuthError.expiredAndUnrefreshable(since: expiry)), completion)
            } else {
                deliverOnMain(.failure(AntigravityAuthError.secretsUnavailable), completion)
            }
            return
        }

        client.refresh(refreshToken: credential.refreshToken) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let tokens):
                self.store(tokens.accessToken, expiry: tokens.expiry, for: .keychain)
                // Source A 永不持久化 rotated refresh_token —— 就地丢弃
                self.deliverOnMain(.success(tokens.accessToken), completion)
            case .failure(let error):
                self.deliverOnMain(.failure(error), completion)
            }
        }
    }

    // MARK: - Private — Source B

    /// `.oauth`：从注入钩子读 refresh token → 刷新 → 若响应带新 refresh_token 则回写持久化。
    private func fetchFromOAuth(accountId: UUID, completion: @escaping (Result<String, Error>) -> Void) {
        guard let client = oauthClient else {
            deliverOnMain(.failure(AntigravityAuthError.secretsUnavailable), completion)
            return
        }
        guard let refreshToken = loadOAuthRefreshToken?(accountId) else {
            deliverOnMain(.failure(AntigravityAuthError.secretsUnavailable), completion)
            return
        }

        client.refresh(refreshToken: refreshToken) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let tokens):
                self.store(tokens.accessToken, expiry: tokens.expiry, for: .oauth(accountId))
                if let rotated = tokens.refreshToken, let persist = self.persistOAuthRefreshToken {
                    // 跳到主队列再调用：这个钩子绑定到 `KeychainManager`，在本项目
                    // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 下它隐式是 MainActor-isolated 的
                    // 普通 class，从这里（`URLSession` 后台完成回调线程）直接调用会是隔离违规。
                    DispatchQueue.main.async { persist(accountId, rotated) }
                }
                self.deliverOnMain(.success(tokens.accessToken), completion)
            case .failure(let error):
                self.deliverOnMain(.failure(error), completion)
            }
        }
    }
}
