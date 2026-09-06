//
//  AntigravityOAuthClient.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-09-06.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import Foundation
import OSLog

/// Token 交换的产物：来自 `exchange` 或 `refresh`。
struct AntigravityTokenSet {
    let accessToken: String
    /// 首次授权必有；刷新时通常为 nil（Google 不轮换）
    let refreshToken: String?
    let expiry: Date
}

/// Google OAuth token 端点封装。四个动作，全部无状态。
/// - Important: 不打印、不落盘任何 token；错误里只带 Google 的 `error` / `error_description`
///   原文（这两个字段本身不敏感）。
nonisolated final class AntigravityOAuthClient {
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let tokenInfoURL = "https://www.googleapis.com/oauth2/v3/tokeninfo"
    private static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!

    private let secrets: AntigravityOAuthSecrets
    private let session: URLSession

    init(secrets: AntigravityOAuthSecrets, session: URLSession = .shared) {
        self.secrets = secrets
        self.session = session
    }

    // MARK: - Exchange

    /// `postToken` 依 grant type 决定错误如何映射：
    /// `authorization_code` 路径上的 400 是 PKCE / redirect_uri 之类的具体失败，必须把 Google 的
    /// `error`/`error_description` 原文透传出去，而不是笼统地当成 refresh token 被吊销。
    private enum GrantType: Equatable {
        case authorizationCode
        case refreshToken
    }

    /// 授权码 → tokens（Source B 首次登录）
    func exchange(
        code: String,
        codeVerifier: String,
        redirectURI: URL,
        completion: @escaping (Result<AntigravityTokenSet, Error>) -> Void
    ) {
        let params: [String: String] = [
            "code": code,
            "client_id": secrets.clientId,
            "client_secret": secrets.clientSecret,
            "redirect_uri": redirectURI.absoluteString,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]
        postToken(params: params, grantType: .authorizationCode, completion: completion)
    }

    // MARK: - Refresh

    /// refresh_token → access_token（两个来源共用）
    /// - Note: 若响应里带了新的 `refresh_token`，Source B 必须持久化它；Source A 必须丢弃它。
    func refresh(
        refreshToken: String,
        completion: @escaping (Result<AntigravityTokenSet, Error>) -> Void
    ) {
        let params: [String: String] = [
            "refresh_token": refreshToken,
            "client_id": secrets.clientId,
            "client_secret": secrets.clientSecret,
            "grant_type": "refresh_token"
        ]
        postToken(params: params, grantType: .refreshToken, completion: completion)
    }

    // MARK: - Token Info

    /// 拿邮箱作为账户标签，顺带验证 token 有效。
    /// - Important: `sub`（Google 账户的稳定数字 id）随 tokeninfo 响应一并下发；`UserSettings`
    ///   用它做 `Account.organizationId`（跨邮箱改名依然稳定），`email` 则作为 `organizationName`
    ///   （对照 `CodexWebLoginCoordinator` 用 email/displayName 的做法）。
    func tokenInfo(
        accessToken: String,
        completion: @escaping (Result<(email: String?, sub: String?, expiry: Date?), Error>) -> Void
    ) {
        var components = URLComponents(string: Self.tokenInfoURL)!
        components.queryItems = [URLQueryItem(name: "access_token", value: accessToken)]
        guard let url = components.url else {
            completion(.failure(AntigravityAuthError.codeExchangeFailed("invalid tokeninfo URL")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.assumesHTTP3Capable = false

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(UsageError.noData))
                return
            }
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                let message = Self.extractErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
                Logger.api.error("Antigravity tokeninfo failed: \(message, privacy: .public)")
                completion(.failure(AntigravityAuthError.codeExchangeFailed(message)))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(TokenInfoResponse.self, from: data)
                let expiry = decoded.exp.flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
                completion(.success((email: decoded.email, sub: decoded.sub, expiry: expiry)))
            } catch {
                completion(.failure(UsageError.decodingError))
            }
        }
        task.resume()
    }

    // MARK: - Revoke

    /// 退出登录时尽力撤销；失败不阻塞本地清理
    func revoke(token: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = URLRequest(url: Self.revokeURL)
        request.httpMethod = "POST"
        request.assumesHTTP3Capable = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "token=\(Self.formURLEncode(token))".data(using: .utf8)

        let task = session.dataTask(with: request) { _, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                completion(.failure(UsageError.httpError(statusCode: httpResponse.statusCode)))
                return
            }
            completion(.success(()))
        }
        task.resume()
    }

    // MARK: - Private — Shared token POST

    private func postToken(
        params: [String: String],
        grantType: GrantType,
        completion: @escaping (Result<AntigravityTokenSet, Error>) -> Void
    ) {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.assumesHTTP3Capable = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(params).data(using: .utf8)

        let task = session.dataTask(with: request) { data, response, error in
            // 绝不记录响应体——即便脱敏过，`id_token`（携带用户邮箱的 bearer 凭据）也可能整段
            // 出现在这里且不被现有正则匹配。只记录 HTTP 状态码。
            if let httpResponse = response as? HTTPURLResponse {
                Logger.api.debug("Antigravity OAuth token response: HTTP \(httpResponse.statusCode)")
            }

            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(UsageError.noData))
                return
            }

            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                let googleError = Self.extractErrorCode(from: data)
                let message = Self.extractErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
                // 只有 refresh_token grant 上的 `invalid_grant` 才代表 refresh token 被撤销；
                // authorization_code grant 上的 400（PKCE / redirect_uri / state 之类）必须把 Google
                // 的原文错误透传出去，否则调试不了具体是哪一步失败。
                if grantType == .refreshToken, googleError == "invalid_grant" {
                    completion(.failure(AntigravityAuthError.refreshTokenRevoked))
                } else {
                    // 原文只进 Logger——`AntigravityAuthError.codeExchangeFailed` 的
                    // `errorDescription` 不再回显它。
                    Logger.api.error("Antigravity code exchange failed: \(message, privacy: .public)")
                    completion(.failure(AntigravityAuthError.codeExchangeFailed(message)))
                }
                return
            }

            do {
                let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
                guard let accessToken = decoded.accessToken else {
                    completion(.failure(UsageError.decodingError))
                    return
                }
                let expiry = Date().addingTimeInterval(TimeInterval(decoded.expiresIn ?? 3600))
                completion(.success(AntigravityTokenSet(
                    accessToken: accessToken,
                    refreshToken: decoded.refreshToken,
                    expiry: expiry
                )))
            } catch {
                completion(.failure(UsageError.decodingError))
            }
        }
        task.resume()
    }

    // MARK: - Private — Wire models

    private nonisolated struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private nonisolated struct TokenInfoResponse: Decodable {
        let email: String?
        /// Google 账户的稳定数字 id；换邮箱也不变，用作 `Account.organizationId`
        let sub: String?
        let exp: String?
    }

    // MARK: - Private — Form encoding

    private static func formEncode(_ params: [String: String]) -> String {
        params.map { "\($0.key)=\(formURLEncode($0.value))" }.joined(separator: "&")
    }

    private static func formURLEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 只取 `error` 字段本身（如 `"invalid_grant"`），用于判断 grant-type 相关的错误分支。
    private static func extractErrorCode(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["error"] as? String
    }

    /// Google 的错误响应形如 `{"error":"invalid_grant","error_description":"..."}`；
    /// 这两个字段本身不敏感，可以原文透传给调用方展示。
    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let error = json["error"] as? String
        let description = json["error_description"] as? String
        switch (error, description) {
        case let (e?, d?): return "\(e): \(d)"
        case let (e?, nil): return e
        default: return nil
        }
    }
}
