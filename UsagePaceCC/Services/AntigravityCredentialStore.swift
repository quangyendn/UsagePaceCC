//
//  AntigravityCredentialStore.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-09-06.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import Foundation
import Security

/// 从 `agy` 写入的 macOS 登录钥匙串条目中解析出的凭据。
/// - Important: `accessToken` / `refreshToken` 绝不持久化到本 App 自己的存储中。
nonisolated struct AntigravityCredential: Sendable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    /// RFC3339 带本地偏移解析而来
    let expiry: Date?
    /// 观察值 "consumer"
    let authMethod: String?

    /// 预留 60s 余量，避免请求在途中过期
    /// - Important: 显式 `nonisolated`——项目把 `SWIFT_DEFAULT_ACTOR_ISOLATION` 设成了
    ///   `MainActor`，没有这个标注这个计算属性会被推断成 MainActor-isolated，而
    ///   `AntigravityTokenProvider.fetchFromKeychain` 从 `nonisolated` 上下文同步读它。
    nonisolated var needsRefresh: Bool { expiry.map { $0 <= Date().addingTimeInterval(60) } ?? true }
}

/// `agy` 凭据读取器 —— 只读，永远只读。
/// - Important: 绝不写入、修改或删除 `svce=gemini` / `acct=antigravity` 这一条目。
///   刷新得到的新 access_token 只存在于内存中，绝不回写钥匙串 —— 回写会让 agy 自己
///   持有的凭据状态出现分歧。
nonisolated enum AntigravityCredentialStore {
    static let service = "gemini"
    static let account = "antigravity"
    private static let payloadPrefix = "go-keyring-base64:"

    /// 同步读取；调用方**必须**在后台队列调用——若这是本次登录会话第一次读取这个条目（尚无
    /// 已授权的 ACL 记录），系统会弹出 ACL 授权框并阻塞，直到用户点了允许/拒绝。
    /// - Important: **全 App 只应该有一个调用点**——`AntigravityTokenProvider.connectKeychain(_:)`，
    ///   而它自己也只应该被 Auth 页 Connect / Reconnect 两个按钮的点击直接调用。这是唯一能
    ///   兑现"后台应用绝不凭空弹出一个跟用户当前操作无关的系统对话框"这条约束的方式。
    /// - Important: 此前这里试图用 `kSecUseAuthenticationContext` + `LAContext.interactionNotAllowed`
    ///   在"例行轮询"路径上把交互降级为静默失败（而不是从调用点上完全消除该次读取）——这个
    ///   guard 对 `agy` 写入的条目是一个**无效**的假设：Apple 的 `SecItem.h`（约 1016-1020 行）
    ///   明确写着 `kSecUseNoAuthenticationUI`"只对 Data Protection keychain 里的条目生效，
    ///   Legacy keychain 条目仍然会在需要时弹出交互框"，而 `security dump-keychain -a` 证实
    ///   `agy` 这个条目正是 Legacy keychain（`SecACL` trusted-application 列表 + `partition_id`
    ///   授权只存在于 Legacy keychain）；对一个 ACL 全部清空的 Legacy 测试条目做过实测探针，
    ///   `LAContext` 守卫下依然直接返回了明文，而不是 `errSecInteractionNotAllowed`。这个守卫
    ///   是个没有效果的摆设，唯一靠得住的做法是**从根上不在非用户手势路径调用这个函数**。
    static func read() throws -> AntigravityCredential {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw AntigravityAuthError.keychainMalformed
            }
            return try decodePayload(data)
        case errSecItemNotFound:
            throw AntigravityAuthError.keychainNotFound
        case errSecMissingEntitlement:
            // 沙盒/签名缺少读取跨 App 钥匙串条目所需的 entitlement —— 这是一个应当单独记录的状态，
            // 不能和下面的「用户拒绝」归并。
            throw AntigravityAuthError.keychainEntitlementMissing(status)
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            // 用户在 ACL 弹窗里点了拒绝，或系统出于其它原因阻止了交互式授权——三者都归入同一个
            // "需要 Reconnect" 状态；这里不可区分"用户真的点了拒绝"与其它系统层面的阻止，但两者
            // 在 UI 上引导的都是同一个 Reconnect 动作，可接受。
            throw AntigravityAuthError.keychainAccessDenied(status)
        default:
            throw AntigravityAuthError.keychainAccessDenied(status)
        }
    }

    /// 廉价探测：条目是否存在（`kSecReturnData: false`，尽量不触发 ACL 弹窗）。
    /// - Note: 与 Codex 的 `isPresent` 同一角色；「存在」不等于「可读」。
    static var isPresent: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess
    }

    /// 纯函数，供脚本 harness 直接验证：从钥匙串原始字节解析出凭据。
    static func decodePayload(_ data: Data) throws -> AntigravityCredential {
        guard let rawString = String(data: data, encoding: .utf8),
              rawString.hasPrefix(payloadPrefix) else {
            throw AntigravityAuthError.keychainMalformed
        }

        let base64Payload = String(rawString.dropFirst(payloadPrefix.count))
        guard let jsonData = Data(base64Encoded: base64Payload) else {
            throw AntigravityAuthError.keychainMalformed
        }

        guard let payload = try? JSONDecoder().decode(KeychainPayload.self, from: jsonData) else {
            throw AntigravityAuthError.keychainMalformed
        }

        guard !payload.token.accessToken.isEmpty else {
            throw AntigravityAuthError.noAccessToken
        }

        return AntigravityCredential(
            accessToken: payload.token.accessToken,
            refreshToken: payload.token.refreshToken,
            tokenType: payload.token.tokenType,
            expiry: AntigravityDateParsing.parseRFC3339(payload.token.expiry),
            authMethod: payload.authMethod
        )
    }

    // MARK: - Private — Wire model

    private struct KeychainPayload: Decodable {
        struct Token: Decodable {
            let accessToken: String
            let tokenType: String
            let refreshToken: String
            let expiry: String

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case tokenType = "token_type"
                case refreshToken = "refresh_token"
                case expiry
            }
        }

        let token: Token
        let authMethod: String?

        enum CodingKeys: String, CodingKey {
            case token
            case authMethod = "auth_method"
        }
    }
}
