//
//  LinearUsageGraphView.swift
//  UsagePaceCC
//
//  Created by Claude on 2026-01-11.
//  Copyright © 2026 f-is-h. All rights reserved.
//

import SwiftUI
import OSLog

/// Linear graph view showing usage pace with ideal pace reference line
/// X-axis: Normalized time (0 = session start, 1 = reset time)
/// Y-axis: Usage percentage (0-100%)
struct LinearUsageGraphView: View {
    let usageData: UsageData?
    /// Codex usage data (P05). Defaulted nil so existing/preview call sites keep compiling unchanged.
    let codexUsageData: CodexUsageData?
    let activeDisplayTypes: [LimitType]
    let isRefreshing: Bool

    init(
        usageData: UsageData?,
        codexUsageData: CodexUsageData? = nil,
        activeDisplayTypes: [LimitType],
        isRefreshing: Bool
    ) {
        self.usageData = usageData
        self.codexUsageData = codexUsageData
        self.activeDisplayTypes = activeDisplayTypes
        self.isRefreshing = isRefreshing
    }

    // MARK: - Constants

    private let graphWidth: CGFloat = 262
    private let graphHeight: CGFloat = 100
    private let padding: CGFloat = 4
    private let gridLineWidth: CGFloat = 0.5
    private let paceLineWidth: CGFloat = 1.5
    private let dotRadius: CGFloat = 5

    /// One resolved point, provider-agnostic. Both Claude (`usageData`) and Codex (`codexUsageData`)
    /// funnel through `resolve(_:)` into this shape so drawing code never branches on provider again.
    private struct ResolvedPoint {
        let percentage: Double
        let resetsAt: Date?
        /// Window length in seconds, when known. Claude points leave this nil (their window length is
        /// looked up from the static 5h/7d table in `calculateElapsedTimeRatio`); Codex points carry it
        /// from `CodexUsageData.LimitData.windowSeconds` (wire: `limit_window_seconds`) because Codex
        /// windows are not reliably 5h/7d — this account's measured primary window is 604800s (7 days).
        let windowSeconds: TimeInterval?
        let color: Color
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            if (usageData != nil || codexUsageData != nil), !isRefreshing {
                // Graph content
                Canvas { context, size in
                    let drawArea = CGRect(
                        x: padding,
                        y: padding,
                        width: size.width - padding * 2,
                        height: size.height - padding * 2
                    )

                    // 1. Draw background grid
                    drawGrid(context: context, in: drawArea)

                    // 2. Draw ideal pace line (dashed diagonal)
                    drawIdealPaceLine(context: context, in: drawArea)

                    // 3. Draw limit points
                    drawLimitPoints(context: context, in: drawArea)
                }
                .frame(width: graphWidth, height: graphHeight)
            } else {
                // Loading or no data state
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 2)
                    .frame(width: graphWidth - padding * 2, height: graphHeight - padding * 2)

                if isRefreshing {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Text("--")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: graphWidth, height: graphHeight)
    }

    // MARK: - Drawing Methods

    /// Draw subtle horizontal grid lines at 25%, 50%, 75%, 100%
    private func drawGrid(context: GraphicsContext, in rect: CGRect) {
        let gridColor = Color.gray.opacity(0.15)

        for percentage in stride(from: 25.0, through: 100.0, by: 25.0) {
            let y = rect.maxY - (CGFloat(percentage) / 100.0 * rect.height)

            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))

            context.stroke(path, with: .color(gridColor), lineWidth: gridLineWidth)
        }

        // Draw vertical grid lines at 25%, 50%, 75%
        for fraction in stride(from: 0.25, through: 0.75, by: 0.25) {
            let x = rect.minX + CGFloat(fraction) * rect.width

            var path = Path()
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))

            context.stroke(path, with: .color(gridColor), lineWidth: gridLineWidth)
        }

        // Draw border
        var borderPath = Path()
        borderPath.addRect(rect)
        context.stroke(borderPath, with: .color(Color.gray.opacity(0.3)), lineWidth: gridLineWidth)
    }

    /// Draw dashed diagonal line representing ideal pace (0,0) to (1,100)
    private func drawIdealPaceLine(context: GraphicsContext, in rect: CGRect) {
        var path = Path()
        // Start from bottom-left (time=0, usage=0) to top-right (time=1, usage=100)
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))

        let dashStyle = StrokeStyle(
            lineWidth: paceLineWidth,
            lineCap: .round,
            dash: [4, 4]
        )

        context.stroke(path, with: .color(Color.gray.opacity(0.5)), style: dashStyle)
    }

    /// Draw colored dots for each active limit type with percentage labels
    private func drawLimitPoints(context: GraphicsContext, in rect: CGRect) {
        // Reset per-draw; Canvas closures re-run on every redraw so this never leaks across frames.
        var drawnLabelRects: [CGRect] = []

        for limitType in activeDisplayTypes {
            guard let resolved = resolve(limitType) else { continue }

            let xNormalized = calculateElapsedTimeRatio(
                resetsAt: resolved.resetsAt,
                windowSeconds: resolved.windowSeconds,
                limitType: limitType
            )
            let point = calculatePoint(percentage: resolved.percentage, xNormalized: xNormalized, in: rect)

            // Draw dot
            let dotRect = CGRect(
                x: point.x - dotRadius,
                y: point.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )

            context.fill(Circle().path(in: dotRect), with: .color(resolved.color))

            // Draw white border for visibility
            context.stroke(
                Circle().path(in: dotRect),
                with: .color(.white.opacity(0.8)),
                lineWidth: 1
            )

            // Draw percentage label next to dot, avoiding already-placed labels
            drawPercentageLabel(
                context: context,
                at: point,
                percentage: resolved.percentage,
                in: rect,
                drawnLabelRects: &drawnLabelRects
            )
        }
    }

    /// Draw percentage label near a data point, greedily avoiding overlap with previously drawn labels.
    /// Tries top-right → below-right → top-left → below-left; if all four collide, falls back to
    /// top-right anyway (a label is never dropped).
    private func drawPercentageLabel(
        context: GraphicsContext,
        at point: CGPoint,
        percentage: Double,
        in rect: CGRect,
        drawnLabelRects: inout [CGRect]
    ) {
        let label = Text("\(Int(percentage))%")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.primary)

        let labelSize = CGSize(width: 28, height: 11)  // Matches the pre-existing 28pt width heuristic
        let gap: CGFloat = 4

        // Candidate origins (top-left corner of the label's drawn rect), in try order.
        let candidates: [CGPoint] = [
            CGPoint(x: point.x + dotRadius + gap, y: point.y - dotRadius - 2 - labelSize.height),   // top-right
            CGPoint(x: point.x + dotRadius + gap, y: point.y + dotRadius + 2),                       // below-right
            CGPoint(x: point.x - dotRadius - gap - labelSize.width, y: point.y - dotRadius - 2 - labelSize.height), // top-left
            CGPoint(x: point.x - dotRadius - gap - labelSize.width, y: point.y + dotRadius + 2)      // below-left
        ]

        func clamped(_ origin: CGPoint) -> CGPoint {
            var x = origin.x
            var y = origin.y
            if x + labelSize.width > rect.maxX { x = rect.maxX - labelSize.width }
            if x < rect.minX { x = rect.minX }
            if y < rect.minY { y = rect.minY }
            if y + labelSize.height > rect.maxY { y = rect.maxY - labelSize.height }
            return CGPoint(x: x, y: y)
        }

        var chosenOrigin = clamped(candidates[0])
        var found = false
        for candidate in candidates {
            let origin = clamped(candidate)
            let candidateRect = CGRect(origin: origin, size: labelSize)
            if !drawnLabelRects.contains(where: { $0.intersects(candidateRect) }) {
                chosenOrigin = origin
                found = true
                break
            }
        }
        if !found {
            // All four slots collide — draw top-right anyway per spec (never drop a label).
            chosenOrigin = clamped(candidates[0])
        }

        let chosenRect = CGRect(origin: chosenOrigin, size: labelSize)
        drawnLabelRects.append(chosenRect)

        // `context.draw(_:at:)` centers vertically on the baseline area; keep drawing at the label's
        // top-left-ish anchor consistent with the original implementation's (labelX, labelY) convention.
        context.draw(label, at: CGPoint(x: chosenOrigin.x, y: chosenOrigin.y + labelSize.height / 2))
    }

    // MARK: - Calculation Methods

    /// Calculate the position of a limit point on the graph
    /// X = elapsed time / total window (0 = just started, 1 = about to reset)
    /// Y = usage percentage
    private func calculatePoint(percentage: Double, xNormalized: CGFloat, in rect: CGRect) -> CGPoint {
        // Convert to canvas coordinates
        // X: 0 (left) = session start, 1 (right) = reset
        let x = rect.minX + xNormalized * rect.width
        // Y: 0 (bottom) = 0%, 1 (top) = 100%
        let y = rect.maxY - (CGFloat(percentage) / 100.0 * rect.height)

        return CGPoint(x: x, y: y)
    }

    /// Calculate the elapsed time ratio (0 = just started, 1 = about to reset)
    /// - Parameters:
    ///   - resetsAt: absolute reset time, if known.
    ///   - windowSeconds: data-driven window length (Codex, from `limit_window_seconds`). When present,
    ///     this is authoritative and the static per-`limitType` table below is skipped entirely.
    ///   - limitType: used only as a fallback lookup when `windowSeconds` is nil (e.g. Claude points,
    ///     which do not carry a window length on `UsageData.LimitData`).
    private func calculateElapsedTimeRatio(
        resetsAt: Date?,
        windowSeconds: TimeInterval?,
        limitType: LimitType
    ) -> CGFloat {
        guard let resetsAt = resetsAt else {
            // If no reset time, assume just started
            return 0
        }

        let totalWindow: TimeInterval
        if let windowSeconds, windowSeconds > 0 {
            totalWindow = windowSeconds
        } else {
            // Fallback only for data with no known window length (all Claude points today).
            // Codex points always carry `windowSeconds` from the wire (P03); this table must never
            // become the source of truth for Codex again — that hardcoded the wrong 5h window before.
            switch limitType {
            case .fiveHour, .codexPrimary:
                totalWindow = 5 * 3600  // 5 hours in seconds
            case .sevenDay, .opusWeekly, .sonnetWeekly, .extraUsage,
                 .codexSecondary, .codexExtraUsage:
                totalWindow = 7 * 24 * 3600  // 7 days in seconds
            }
            Logger.api.debug("LinearUsageGraphView: falling back to static window table for \(limitType.rawValue, privacy: .public) (windowSeconds was nil)")
        }

        let remainingTime = resetsAt.timeIntervalSinceNow
        let elapsedTime = totalWindow - remainingTime

        // Clamp to 0-1 range
        let ratio = elapsedTime / totalWindow
        return CGFloat(max(0, min(1, ratio)))
    }

    /// Resolve a `LimitType` into a provider-agnostic point, pulling from `usageData` for the 5 Claude
    /// cases (moved verbatim from the old `getLimitData`/`colorForLimitType`) and from `codexUsageData`
    /// for the 3 Codex cases.
    private func resolve(_ limitType: LimitType) -> ResolvedPoint? {
        switch limitType {
        case .fiveHour:
            guard let data = usageData, let limit = data.fiveHour else { return nil }
            return ResolvedPoint(
                percentage: limit.percentage,
                resetsAt: limit.resetsAt,
                windowSeconds: nil,
                color: UsageColorScheme.fiveHourColorSwiftUI(limit.percentage)
            )
        case .sevenDay:
            guard let data = usageData, let limit = data.sevenDay else { return nil }
            return ResolvedPoint(
                percentage: limit.percentage,
                resetsAt: limit.resetsAt,
                windowSeconds: nil,
                color: UsageColorScheme.sevenDayColorSwiftUI(limit.percentage)
            )
        case .opusWeekly:
            guard let data = usageData, let limit = data.opus else { return nil }
            return ResolvedPoint(
                percentage: limit.percentage,
                resetsAt: limit.resetsAt,
                windowSeconds: nil,
                color: Color(UsageColorScheme.opusWeeklyColor(limit.percentage))
            )
        case .sonnetWeekly:
            guard let data = usageData, let limit = data.sonnet else { return nil }
            return ResolvedPoint(
                percentage: limit.percentage,
                resetsAt: limit.resetsAt,
                windowSeconds: nil,
                color: Color(UsageColorScheme.sonnetWeeklyColor(limit.percentage))
            )
        case .extraUsage:
            // ExtraUsageData has different structure and no resetsAt; keep plotting it at x=0
            // (elapsed-ratio 0), matching the pre-existing convention.
            guard let data = usageData, let extra = data.extraUsage, let percentage = extra.percentage else {
                return nil
            }
            return ResolvedPoint(
                percentage: percentage,
                resetsAt: nil,
                windowSeconds: nil,
                color: Color(UsageColorScheme.extraUsageColor(percentage))
            )
        case .codexPrimary:
            guard let limit = codexUsageData?.primary else { return nil }
            return ResolvedPoint(
                percentage: limit.percentage,
                resetsAt: limit.resetsAt,
                windowSeconds: limit.windowSeconds,
                color: UsageColorScheme.codexPrimaryColorSwiftUI(limit.percentage)
            )
        case .codexSecondary:
            // secondary_window is null on this account today (P01/P03 finding); guard makes that a
            // clean "no point drawn" rather than a fabricated dot at x=0,y=0.
            guard let limit = codexUsageData?.secondary else { return nil }
            return ResolvedPoint(
                percentage: limit.percentage,
                resetsAt: limit.resetsAt,
                windowSeconds: limit.windowSeconds,
                color: UsageColorScheme.codexSecondaryColorSwiftUI(limit.percentage)
            )
        case .codexExtraUsage:
            // Same x=0 convention as Claude's `.extraUsage` (no resetsAt), for consistency.
            guard let extra = codexUsageData?.extraUsage, let percentage = extra.percentage else {
                return nil
            }
            return ResolvedPoint(
                percentage: percentage,
                resetsAt: nil,
                windowSeconds: nil,
                color: UsageColorScheme.codexExtraUsageColorSwiftUI(percentage)
            )
        }
    }
}

// MARK: - Preview

struct LinearUsageGraphView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            // Normal state with data (Claude only — unchanged from before P05)
            LinearUsageGraphView(
                usageData: UsageData(
                    fiveHour: UsageData.LimitData(
                        percentage: 45,
                        resetsAt: Date().addingTimeInterval(3600 * 2.5)
                    ),
                    sevenDay: UsageData.LimitData(
                        percentage: 20,
                        resetsAt: Date().addingTimeInterval(3600 * 24 * 5)
                    ),
                    opus: nil,
                    sonnet: nil,
                    extraUsage: nil
                ),
                activeDisplayTypes: [.fiveHour, .sevenDay],
                isRefreshing: false
            )

            // 3-point sample: Claude 5h + Claude 7d + Codex primary (7-day window, per P01 finding)
            LinearUsageGraphView(
                usageData: UsageData(
                    fiveHour: UsageData.LimitData(
                        percentage: 45,
                        resetsAt: Date().addingTimeInterval(3600 * 2.5)
                    ),
                    sevenDay: UsageData.LimitData(
                        percentage: 20,
                        resetsAt: Date().addingTimeInterval(3600 * 24 * 5)
                    ),
                    opus: nil,
                    sonnet: nil,
                    extraUsage: nil
                ),
                codexUsageData: CodexUsageData(
                    primary: CodexUsageData.LimitData(
                        percentage: 62,
                        resetsAt: Date().addingTimeInterval(3600 * 24 * 4),
                        windowSeconds: 604800
                    ),
                    secondary: nil,
                    extraUsage: nil
                ),
                activeDisplayTypes: [.fiveHour, .sevenDay, .codexPrimary],
                isRefreshing: false
            )

            // Colliding-labels case: Claude 5h and Codex primary land at nearly the same
            // (x, y), exercising the greedy de-collision fallback slots.
            LinearUsageGraphView(
                usageData: UsageData(
                    fiveHour: UsageData.LimitData(
                        percentage: 44,
                        resetsAt: Date().addingTimeInterval(3600 * 2.5)
                    ),
                    sevenDay: nil,
                    opus: nil,
                    sonnet: nil,
                    extraUsage: nil
                ),
                codexUsageData: CodexUsageData(
                    primary: CodexUsageData.LimitData(
                        percentage: 46,
                        resetsAt: Date().addingTimeInterval(3600 * 2.5 + 60),
                        windowSeconds: 5 * 3600
                    ),
                    secondary: nil,
                    extraUsage: nil
                ),
                activeDisplayTypes: [.fiveHour, .codexPrimary],
                isRefreshing: false
            )

            // Loading state
            LinearUsageGraphView(
                usageData: nil,
                activeDisplayTypes: [.fiveHour],
                isRefreshing: true
            )
        }
        .padding()
    }
}
