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
    /// 青色
    case teal
    /// 紫色
    case purple
    /// 橙色
    case orange
    /// 粉色
    case pink
    /// 绿色
    case green
    /// 靛蓝色
    case indigo
    /// 黄色
    case yellow

    /// 对应的 SwiftUI Color
    var swiftUIColor: Color {
        switch self {
        case .blue: return .blue
        case .teal: return .teal
        case .purple: return .purple
        case .orange: return .orange
        case .pink: return .pink
        case .green: return .green
        case .indigo: return .indigo
        case .yellow: return .yellow
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
