//
//  AntigravityLoopbackServer.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-09-06.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import Foundation
import Network
import OSLog

/// 一次性回环 HTTP 监听器：绑定 127.0.0.1 的临时端口，只接一个匹配 `/callback` 的请求，
/// 回一段「可以关掉这个页面了」的 HTML，然后立刻关闭。
/// - Important: 沙盒下监听端口需要 `com.apple.security.network.server` entitlement。
///   缺这个 entitlement 时 `NWListener` 会直接失败 —— 要映射成
///   `AntigravityAuthError.loopbackFailed` 并在日志里点名 entitlement，别让它变成无声失败。
/// - Important: 端口只有在 `NWListener` 的 `.ready` 状态回调里（`queue` 私有队列，异步）才会被
///   赋值。调用方**不能**在 `start()` 返回后同步读取端口 —— 那时端口恒为 `nil`。
///   端口通过 `onReady` 回调异步交付；构造 `redirect_uri` 必须发生在这个回调里。
/// - Important: `listener` / `completion` / `timeoutWorkItem` 只允许在私有队列 `queue`
///   上读写，杜绝调用方线程（`start`/`stop`）与 `NWListener` 回调线程之间的数据竞争。
/// `@unchecked Sendable`: all mutable state is confined to the private `queue` (see the class doc
/// above); this is a manually-verified invariant, not something the compiler can
/// check, hence `@unchecked` rather than a plain `Sendable` conformance.
nonisolated final class AntigravityLoopbackServer: @unchecked Sendable {

    /// 私有队列上的可变状态，只由 `queue` 上运行的代码触碰。
    private var listener: NWListener?
    private var completion: ((Result<(code: String, state: String), Error>) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    /// 本轮 `start()` 是否已经交付过终态结果 —— 保证 `completion` 只被调用一次。
    private var finished = false

    private let queue = DispatchQueue(label: "com.usagepacecc.antigravity.loopback")

    /// 单个请求行累积的字节上限，防止恶意/异常客户端喂无穷数据。
    private static let maxRequestBytes = 16 * 1024

    /// 关闭页面的 HTML；正文文案本地化（`L.SettingsAuth.antigravityBrowserPageBody`）。这个类
    /// 整体是 `nonisolated`，不能在这里直接触碰 MainActor 隔离的 `L.*` 静态属性——本地化文案改由
    /// `start(closeMeMessage:...)` 的调用方（`AntigravitySignInCoordinator`，MainActor 隔离）取好后
    /// 传进来，`start()` 只在 `queue` 上把拼好的 HTML 写进 `self.closeMeHTML`，符合类顶部的并发不变量。
    /// 缺省值只在 `start()` 从未被调用过时才可能被用到（理论上不会发生，纯防御）。
    private var closeMeHTML = AntigravityLoopbackServer.buildCloseMeHTML(body: "Sign-in complete. You can close this window.")

    /// - Parameter body: 已本地化、纯文本的正文（不含任何 HTML 标签）；本函数负责转义并拼出完整页面。
    ///   `charset=utf-8` 显式声明，避免 CJK/法语重音字符在浏览器里乱码。
    private static func buildCloseMeHTML(body: String) -> String {
        let escaped = body
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>Antigravity</title></head>
        <body style="font-family: -apple-system, sans-serif; text-align: center; padding-top: 4em;">
        <p>\(escaped)</p>
        </body></html>
        """
    }

    // MARK: - Public

    /// - Parameters:
    ///   - timeout: 硬超时，默认 180s
    ///   - closeMeMessage: 关闭页正文，已本地化的纯文本（不含 HTML 标签）。调用方必须在自己的
    ///     （MainActor 隔离的）上下文里取好 `L.SettingsAuth.antigravityBrowserPageBody` 再传进来——
    ///     这个类整体 `nonisolated`，不能在内部直接读取 MainActor 隔离的 `L.*` 静态属性。
    ///   - onReady: 端口绑定成功后异步回调（主线程），用于拼 `redirect_uri`
    ///   - completion: 终态结果；保证恰好被调用一次，主线程回调
    func start(
        timeout: TimeInterval = 180,
        closeMeMessage: String,
        onReady: @escaping (UInt16) -> Void,
        completion: @escaping (Result<(code: String, state: String), Error>) -> Void
    ) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            Logger.api.error("Antigravity loopback: NWListener 创建失败，检查 com.apple.security.network.server entitlement — \(error.localizedDescription, privacy: .public)")
            throw AntigravityAuthError.loopbackFailed(underlying: error)
        }

        let localizedCloseMeHTML = AntigravityLoopbackServer.buildCloseMeHTML(body: closeMeMessage)

        queue.async { [weak self] in
            guard let self = self else { return }
            self.closeMeHTML = localizedCloseMeHTML

            // 若上一轮 `start()` 还没走到终态就又被调用，必须先收尾上一轮：
            // `finish` 会交付它悬空的 `completion`（不再悄悄丢弃）、取消它的 `timeoutWorkItem`
            // （否则 180s 后误把这一轮当成超时强行 finish 掉）、并 cancel 它的 `NWListener`
            // （否则端口泄漏不释放）。首次调用时 `self.completion` 为 nil，`finish` 会直接
            // no-op，安全。
            if !self.finished {
                self.finish(.failure(AntigravityAuthError.signInCancelled))
            }

            self.finished = false
            self.completion = completion
            self.listener = newListener

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }

            newListener.stateUpdateHandler = { [weak self] nwState in
                guard let self = self else { return }
                self.queue.async {
                    // 若这一轮已经交付过终态（例如被更晚一次 `start()` 或 `stop()` 抢先收尾），
                    // 一个仍在排队的 `.ready` 回调绝不能再往下走——它会呈现一个属于已取消会话的
                    // 浏览器窗口，而 `completeOnce` 早已跑过、不会再去 dismiss 它。
                    guard !self.finished else { return }
                    switch nwState {
                    case .ready:
                        guard let boundPort = newListener.port?.rawValue else {
                            self.finish(.failure(AntigravityAuthError.loopbackFailed(underlying: nil)))
                            return
                        }
                        Logger.api.debug("Antigravity loopback: 监听已就绪，端口 \(boundPort)")
                        DispatchQueue.main.async { onReady(boundPort) }
                    case .failed(let error):
                        Logger.api.error("Antigravity loopback: 监听失败 — \(error.localizedDescription, privacy: .public)")
                        self.finish(.failure(AntigravityAuthError.loopbackFailed(underlying: error)))
                    default:
                        break
                    }
                }
            }

            newListener.start(queue: self.queue)

            let workItem = DispatchWorkItem { [weak self] in
                self?.finish(.failure(AntigravityAuthError.loopbackFailed(underlying: nil)))
            }
            self.timeoutWorkItem = workItem
            self.queue.asyncAfter(deadline: .now() + timeout, execute: workItem)
        }
    }

    /// 用户取消 / 协调器提前收尾。**必须**交付一次终态结果，绝不能让调用方的 completion 悬空。
    /// 若本轮已经交付过结果，是无害的重复调用。
    func stop() {
        queue.async { [weak self] in
            self?.finish(.failure(AntigravityAuthError.signInCancelled))
        }
    }

    // MARK: - Private — Connection handling (all on `queue`)

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            var accumulated = buffer
            if let data = data {
                accumulated.append(data)
            }

            // 只有确认收到完整的请求行（CRLF 已到达）才解析，否则一个被 TCP 分片切断的首包
            // 会被当成完整请求处理，截断 `code`。
            if let requestString = String(data: accumulated, encoding: .utf8),
               requestString.contains("\r\n") {
                let firstLine = requestString
                    .split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false)
                    .first ?? ""
                self.respond(on: connection, requestLine: String(firstLine))
                return
            }

            if isComplete || error != nil || accumulated.count > Self.maxRequestBytes {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: accumulated)
        }
    }

    /// 解析请求行（如 `GET /callback?code=xxx&state=yyy HTTP/1.1`）。
    /// 只有路径恰好是 `/callback` 时才消费这一发监听机会；其余请求（例如浏览器的探测连接）
    /// 一律以最简响应结束连接，但不触发 `finish`（路径未校验时同样安全，无需额外处理）。
    private func respond(on connection: NWConnection, requestLine: String) {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
              components.path == "/callback" else {
            sendNotFoundAndClose(on: connection)
            return
        }

        sendCloseMePageAndClose(on: connection)

        let queryItems = components.queryItems ?? []
        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            finish(.failure(AntigravityAuthError.codeExchangeFailed(error)))
            return
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value,
              let state = queryItems.first(where: { $0.name == "state" })?.value else {
            finish(.failure(AntigravityAuthError.loopbackFailed(underlying: nil)))
            return
        }

        finish(.success((code: code, state: state)))
    }

    private func sendCloseMePageAndClose(on connection: NWConnection) {
        let responseBody = closeMeHTML
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(responseBody.utf8.count)\r
        Connection: close\r
        \r
        \(responseBody)
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendNotFoundAndClose(on connection: NWConnection) {
        let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// 交付终态结果，保证恰好一次；只在 `queue` 上调用。
    private func finish(_ result: Result<(code: String, state: String), Error>) {
        guard !finished, let completion = completion else { return }
        finished = true
        self.completion = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            completion(result)
        }
    }
}
