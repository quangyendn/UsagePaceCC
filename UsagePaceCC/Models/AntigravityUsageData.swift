//
//  AntigravityUsageData.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-09-06.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import Foundation

/// `retrieveUserQuotaSummary` 的原始响应；字段名与线上 JSON 完全一致，不做重命名。
/// - Important: `groups` / `buckets` 是服务端驱动的动态数组，禁止按 `bucketId` 硬编码索引。
nonisolated struct AntigravityUsageResponse: Decodable {
    struct Bucket: Decodable {
        let bucketId: String
        let displayName: String
        /// 开放字符串枚举，当前仅观察到 "weekly"；未知值一律降级为窗口时长未知。
        let window: String
        /// RFC3339，含 UTC 偏移
        let resetTime: String
        /// `remainingFraction == 1` 时服务端不下发该字段，必须可选
        let description: String?
        /// 剩余比例 0...1，**不是**使用量
        let remainingFraction: Double
    }

    struct Group: Decodable {
        let displayName: String
        let description: String?
        let buckets: [Bucket]
    }

    let groups: [Group]
    let description: String?
}

/// 应用内部模型：把嵌套的 group/bucket 拍平成有序列表，并在此处**唯一一次**完成
/// `remainingFraction` → 使用百分比的取反，之后所有渲染层只认使用百分比。
struct AntigravityUsageData: Equatable {
    struct Bucket: Equatable {
        let bucketId: String
        /// 来自 `group.displayName`（如 "Gemini Models"）。仅作 tooltip 用；
        /// 图例文案走本地化静态标签（见 `L.LimitTypes.antigravityPrimary`/`antigravitySecondary`）。
        let groupDisplayName: String
        /// 来自 `bucket.displayName`
        let bucketDisplayName: String
        let resetsAt: Date?
        /// 窗口时长（秒）；`window` 无法识别时为 nil —— 绝不臆造默认值
        let windowSeconds: TimeInterval?
        /// 剩余比例，原始值 0...1
        let remainingFraction: Double

        /// 使用百分比 0...100（与 Claude/Codex 渲染层同一语义）
        var usagePercentage: Double {
            min(100, max(0, (1 - remainingFraction) * 100))
        }
    }

    /// 全部 bucket，顺序 = 服务端 group 顺序 × bucket 顺序
    let buckets: [Bucket]
    /// 整体说明文案（响应顶层 `description`），用于 tooltip
    let description: String?

    var primary: Bucket? { buckets.first }
    var secondary: Bucket? { buckets.count > 1 ? buckets[1] : nil }

    /// 纯函数映射，无 I/O —— 由 `scripts/verify-antigravity-parsing.swift` 直接调用验证
    static func from(_ response: AntigravityUsageResponse) -> AntigravityUsageData {
        let flattened = response.groups.flatMap { group in
            group.buckets.map { bucket in
                Bucket(
                    bucketId: bucket.bucketId,
                    groupDisplayName: group.displayName,
                    bucketDisplayName: bucket.displayName,
                    resetsAt: AntigravityDateParsing.parseRFC3339(bucket.resetTime),
                    windowSeconds: AntigravityWindow.seconds(for: bucket.window),
                    remainingFraction: bucket.remainingFraction
                )
            }
        }
        return AntigravityUsageData(buckets: flattened, description: response.description)
    }
}

/// 窗口时长映射。开放枚举：识别不了就返回 nil，让图表跳过该点、图例照常渲染。
enum AntigravityWindow {
    static func seconds(for raw: String) -> TimeInterval? {
        switch raw.lowercased() {
        case "weekly":            return 604_800
        case "daily":             return 86_400
        case "5h", "five_hour":   return 18_000
        default:                  return nil
        }
    }
}

/// RFC3339（带本地 UTC 偏移）日期解析，`AntigravityCredentialStore` 与
/// `AntigravityUsageData.from(_:)` 共用同一套逻辑。
/// - Important: 钥匙串 / API 里的时间戳都带偏移（如 `+07:00`），必须先尝试
///   `.withInternetDateTime`，失败再退回 `.withFractionalSeconds`；绝不假设 UTC。
nonisolated enum AntigravityDateParsing {
    static func parseRFC3339(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}
