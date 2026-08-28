//
//  AccountColor.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-08-27.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import SwiftUI

// MARK: - 账户颜色

/// 固定调色板而非任意 RGB：Account 通过 Keychain 以 JSON 形式持久化，
/// 固定 case 的 Codable 往返简单可靠，避免自定义 Color/NSColor 编解码的复杂度。
enum AccountColor: String, Codable, CaseIterable {
    /// 蓝色
    case blue
    /// 橙色
    case orange
    /// 水鸭色
    case aqua
    /// 黄色
    case yellow
    /// 洋红色
    case magenta
    /// 绿色
    case green
    /// 紫罗兰色
    case violet
    /// 红色
    case red

    /// 旧调色板 rawValue 到新调色板 case 的映射：避免 Keychain 中持久化的旧颜色名
    /// （如 "teal"/"purple"/"indigo"/"pink"）在解码时因未知 rawValue 抛出
    /// DecodingError，进而导致 KeychainManager.loadAccounts() 的 try? 把整个账户
    /// 数组都判为 nil、最终被空数组覆盖保存（彻底丢失所有已保存账户的 session key）。
    private static let legacyRawValueAliases: [String: AccountColor] = [
        "teal": .aqua,
        "purple": .violet,
        "indigo": .violet,
        "pink": .magenta,
    ]

    /// 自定义解码：未知 rawValue（包括重命名前的旧调色板值）一律回退映射或默认
    /// 为 .blue，绝不向上抛出 —— 防止单个账户的过期颜色值拖垮整个账户数组的解码。
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let matched = AccountColor(rawValue: raw) {
            self = matched
        } else {
            self = Self.legacyRawValueAliases[raw] ?? .blue
        }
    }

    /// 对应的 SwiftUI Color：8 组浅色/深色十六进制值，经过色盲友好性与弹出窗口灰色背景对比度
    /// 验证的固定调色板，顺序即区分度设计的一部分——相邻两项对色觉缺陷用户仍可区分，不可重排。
    var swiftUIColor: Color {
        switch self {
        case .blue: return .dynamic(light: "#2a78d6", dark: "#3987e5")
        case .orange: return .dynamic(light: "#eb6834", dark: "#d95926")
        case .aqua: return .dynamic(light: "#1baf7a", dark: "#199e70")
        case .yellow: return .dynamic(light: "#eda100", dark: "#c98500")
        case .magenta: return .dynamic(light: "#e87ba4", dark: "#d55181")
        case .green: return .dynamic(light: "#008300", dark: "#22b522")
        case .violet: return .dynamic(light: "#4a3aa7", dark: "#9085e9")
        case .red: return .dynamic(light: "#e34948", dark: "#e66767")
        }
    }

    /// 默认颜色必须在多次启动之间保持稳定，直到用户手动选择；
    /// String.hashValue 每次进程启动都会重新播种（哈希随机化），不能使用，
    /// 因此改为对 UUID 的原始 16 字节求和，结果与进程无关、恒定不变。
    static func deterministicDefault(for accountId: UUID) -> AccountColor {
        let all = Self.allCases
        let bytes = withUnsafeBytes(of: accountId.uuid) { Array($0) }
        let sum = bytes.reduce(0) { $0 + Int($1) }
        return all[sum % all.count]
    }
}
