//
//  CodexCLIAuthReader.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-08-17.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import Foundation

/// 从 Codex CLI 自己的凭据文件中解析出的认证信息
/// - Important: `accessToken` 由 CLI 自身轮换，绝不持久化，每次读取都是即时的
struct CodexCLIAuth: Sendable {
    /// Bearer token，用于 `/backend-api/wham/usage`
    let accessToken: String
    /// `tokens.account_id`
    let accountId: String
    /// 邮箱，best-effort 取自 `id_token` claims
    let email: String?
    /// `https://api.openai.com/auth` claim 中的 `chatgpt_account_id` —— D12 账户比对的关键字段
    let chatgptAccountId: String?
    /// 订阅计划类型，例如 "plus"
    let planType: String?
    /// `access_token` 的 `exp`（约 10 天有效期）
    let expiresAt: Date?
    /// `auth.json` 中的 `last_refresh`
    let lastRefresh: Date?

    /// 是否已过期（`expiresAt` 缺失时视为未过期，交由调用方按 `noAccessToken` 等其它错误处理）
    var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }
}

/// Codex CLI 凭据读取失败的具体原因
/// - Note: `notInstalled` 与 `sandboxDenied` 对应两种完全不同的用户提示（P07），不可合并
enum CodexCLIAuthError: Error {
    /// `~/.codex/auth.json` 不存在（`ENOENT` / `NSCocoaErrorDomain` 260）—— Codex CLI 未安装/未登录
    case notInstalled
    /// 读取被沙盒拒绝（`EPERM` / `NSCocoaErrorDomain` 257）—— entitlement 未生效或被移除
    case sandboxDenied
    /// 文件存在但内容无法解析为预期结构
    case malformed
    /// 文件可解析，但 `tokens.access_token` 缺失或为空
    case noAccessToken
    /// `access_token` 已过期；D10：绝不在此基础上发起 refresh 请求
    case tokenExpired(since: Date)
}

/// Codex CLI 凭据读取器 —— 整个应用中唯一直接触碰文件系统的组件
/// - Important: 只读，永远只读（D10）。绝不写入、绝不移动、绝不删除 `~/.codex/` 下的任何文件，
///   也绝不调用任何 OAuth / refresh 端点。
nonisolated enum CodexCLIAuthReader {
    // MARK: - Path Resolution

    /// `auth.json` 的完整路径
    /// - Note: 优先读取 `$CODEX_HOME`（沙盒化 GUI App 通常不会继承 shell 的环境变量，这里只是
    ///   opportunistic 尝试），否则回退到真实用户主目录下的 `.codex/auth.json`
    static var authFileURL: URL {
        let environment = ProcessInfo.processInfo.environment
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        }
        return URL(fileURLWithPath: realHomeDirectory())
            .appendingPathComponent(".codex")
            .appendingPathComponent("auth.json")
    }

    /// 廉价的可读性探测，仅一次 `stat`，不做解析
    /// - Important: 不要用 `FileManager.fileExists(atPath:)` —— 沙盒拒绝读取时它依然返回 `true`
    ///   （元数据可见但内容不可读），会把"权限被拒绝"误判为"已安装"。`isReadableFile(atPath:)`
    ///   在两种情形下都被验证给出了正确结果（P01 spike）。
    static var isPresent: Bool {
        FileManager.default.isReadableFile(atPath: authFileURL.path)
    }

    // MARK: - Read

    /// 读取并解析 Codex CLI 的凭据文件
    /// - Returns: 解析出的 `CodexCLIAuth`
    /// - Throws: `CodexCLIAuthError`；`exp` 已过期时抛出 `.tokenExpired`，绝不会走到网络请求
    static func read() throws -> CodexCLIAuth {
        let data = try readData()
        let authFile = try decodeAuthFile(data)

        guard let accessToken = authFile.tokens?.accessToken, !accessToken.isEmpty else {
            throw CodexCLIAuthError.noAccessToken
        }

        let accessClaims = decodeJWTPayload(accessToken)
        let expiresAt = (accessClaims?["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }

        // id_token 仅作为 claims 载体使用，其自身 exp（约 1 小时）被显式忽略，不参与任何有效性判断
        var email: String?
        var chatgptAccountId: String?
        var planType: String?
        if let idToken = authFile.tokens?.idToken, let idClaims = decodeJWTPayload(idToken) {
            email = idClaims["email"] as? String
            if let authClaim = idClaims["https://api.openai.com/auth"] as? [String: Any] {
                chatgptAccountId = authClaim["chatgpt_account_id"] as? String
                planType = authClaim["chatgpt_plan_type"] as? String
            }
        }

        let auth = CodexCLIAuth(
            accessToken: accessToken,
            accountId: authFile.tokens?.accountId ?? "",
            email: email,
            chatgptAccountId: chatgptAccountId,
            planType: planType,
            expiresAt: expiresAt,
            lastRefresh: authFile.lastRefresh.flatMap(parseLastRefresh)
        )

        // D10: 我们只读不写。access_token 过期时绝不调用 OAuth refresh —
        // OpenAI 可能轮换 refresh_token，应用刷新会使 Codex CLI 自己持有的 token 失效，
        // 把用户从自己的 CLI 里登出。过期状态一律上报给用户，由用户运行 codex 命令自行刷新。
        // 不要"修复"这里。
        if let expiresAt, expiresAt <= Date() {
            throw CodexCLIAuthError.tokenExpired(since: expiresAt)
        }

        return auth
    }

    // MARK: - Private — File I/O

    /// 读取原始文件数据，将 `NSCocoaErrorDomain` 的 257/260 映射为不同的错误 case
    private static func readData() throws -> Data {
        do {
            return try Data(contentsOf: authFileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileReadNoSuchFileError:
                throw CodexCLIAuthError.notInstalled
            case NSFileReadNoPermissionError:
                throw CodexCLIAuthError.sandboxDenied
            default:
                throw CodexCLIAuthError.malformed
            }
        } catch {
            throw CodexCLIAuthError.malformed
        }
    }

    /// 解析真实用户主目录（沙盒下 `NSHomeDirectory()` 返回的是容器路径，不可用）
    /// - Note: `getpwuid(getuid())` 在沙盒环境内已经过 P01 spike 验证可用
    private static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dirPointer = pw.pointee.pw_dir {
            return String(cString: dirPointer)
        }
        return NSHomeDirectory()
    }

    // MARK: - Private — JSON Decoding

    private struct CodexAuthTokens: Decodable {
        let idToken: String?
        let accessToken: String?
        let refreshToken: String?
        let accountId: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case accountId = "account_id"
        }
    }

    private struct CodexAuthFile: Decodable {
        let authMode: String?
        /// `OPENAI_API_KEY` 在 ChatGPT 订阅登录下 present-but-null，解码为 `String?` 并忽略
        let openAIAPIKey: String?
        let tokens: CodexAuthTokens?
        let lastRefresh: String?

        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode"
            case openAIAPIKey = "OPENAI_API_KEY"
            case tokens
            case lastRefresh = "last_refresh"
        }
    }

    private static func decodeAuthFile(_ data: Data) throws -> CodexAuthFile {
        do {
            return try JSONDecoder().decode(CodexAuthFile.self, from: data)
        } catch {
            throw CodexCLIAuthError.malformed
        }
    }

    /// 解码 JWT 的 payload 段（base64url，仅用 Foundation，不引入第三方 JWT 库）
    /// - Note: 解码失败一律返回 nil，不抛出错误（`access_token` 缺失是唯一必须抛出的情形）
    /// - Important: internal（非 private），供 `CodexBrowserUsageSource` 复用同一套 base64url 解码逻辑（D12），
    ///   避免在两处重复实现
    static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func parseLastRefresh(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}
