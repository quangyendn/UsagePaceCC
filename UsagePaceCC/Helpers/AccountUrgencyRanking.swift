//
//  AccountUrgencyRanking.swift
//  UsagePaceCC
//
//  Created by Claude Code on 2026-08-27.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import Foundation

/// 纯函数：从一组账户用量快照中选出最紧迫的若干个（供状态栏图标使用）。
/// Provider 无关——调用方（phase 05）负责先按 provider 分组，再分别调用本函数。
/// - Parameters:
///   - snapshots: 待排序的账户用量快照
///   - limit: 返回的最大数量，默认 2
/// - Returns: 按紧迫度降序排列的前 `limit` 个快照
func topUrgentAccounts(from snapshots: [AccountUsageSnapshot], limit: Int = 2) -> [AccountUsageSnapshot] {
    snapshots.sorted { lhs, rhs in
        let lhsScore = urgencyScore(lhs)
        let rhsScore = urgencyScore(rhs)
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }
        // 分数相同时按 accountId 升序排列，确保排序结果与输入顺序无关、每次调用一致，
        // 避免菜单栏图标因 sorted(by:) 的不稳定排序而随机交换
        return lhs.accountId.uuidString < rhs.accountId.uuidString
    }.prefix(limit).map { $0 }
}

/// 紧迫度评分：优先使用 5 小时窗口百分比，其次 7 天窗口百分比；
/// 两者皆无数据时返回 -1，确保排序时垫底
private func urgencyScore(_ snapshot: AccountUsageSnapshot) -> Double {
    if let fiveHour = snapshot.fiveHour {
        return fiveHour.percentage
    }
    if let sevenDay = snapshot.sevenDay {
        return sevenDay.percentage
    }
    return -1  // no data at all sorts last
}
