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
    /// All saved Claude accounts (P03). Drives the new per-account 5h/7d chart points; empty array
    /// keeps existing/preview call sites compiling unchanged (no account-driven points drawn).
    let claudeSnapshots: [AccountUsageSnapshot]

    init(
        usageData: UsageData?,
        codexUsageData: CodexUsageData? = nil,
        activeDisplayTypes: [LimitType],
        isRefreshing: Bool,
        claudeSnapshots: [AccountUsageSnapshot] = []
    ) {
        self.usageData = usageData
        self.codexUsageData = codexUsageData
        self.activeDisplayTypes = activeDisplayTypes
        self.isRefreshing = isRefreshing
        self.claudeSnapshots = claudeSnapshots
    }

    /// Legacy `LimitType`s still rendered via the old single-account `resolve(_:)` path (P03 scope
    /// correction): 5h/7d (Claude) and codexPrimary now render via the new account-driven path
    /// (`drawAccountPoints`) instead, to avoid double-drawing when exactly 1 account exists per provider.
    private let legacyLimitTypes: Set<LimitType> = [.opusWeekly, .sonnetWeekly, .extraUsage, .codexExtraUsage]

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
        /// How the dot is drawn (P03). `.legacy` preserves today's filled-dot-with-white-border look
        /// (still used by `legacyLimitTypes`); `.outline`/`.filled` are the new account-driven markers
        /// (5h = outline ring, 7d = filled ring), both colored from `AccountColor` rather than percentage.
        enum MarkerStyle {
            case legacy
            case outline
            case filled
        }

        let percentage: Double
        let resetsAt: Date?
        /// Window length in seconds, when known. Claude points leave this nil (their window length is
        /// looked up from the static 5h/7d table in `calculateElapsedTimeRatio`); Codex points carry it
        /// from `CodexUsageData.LimitData.windowSeconds` (wire: `limit_window_seconds`) because Codex
        /// windows are not reliably 5h/7d — this account's measured primary window is 604800s (7 days).
        let windowSeconds: TimeInterval?
        let color: Color
        /// nil for `legacyLimitTypes` points (no per-account identity, unchanged from before P03).
        let accountId: UUID?
        let markerStyle: MarkerStyle
        /// Static window length (seconds) to fall back to in `calculateAccountElapsedRatio` when
        /// `windowSeconds` is nil (code-review fix 3b). Explicitly provider-scoped rather than guessed
        /// from `markerStyle`: Claude's fiveHour/sevenDay windows really are always 18000s/604800s, so
        /// they get a value here; Codex's window length is data-driven and must never be guessed, so
        /// its points always pass nil (relying purely on `windowSeconds`, or not being plotted at all —
        /// see `AccountUsageSnapshot.codexWrapper`'s `isPlottable`-equivalent guard).
        let fallbackWindowSeconds: TimeInterval?
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

        // New (P03): per-account 5h/7d (+ Codex primary, wrapped) points, colored by `AccountColor`.
        drawAccountPoints(context: context, in: rect, drawnLabelRects: &drawnLabelRects)

        // Legacy (unchanged by P03): remaining single-account limit types still drive their dot from
        // `usageData`/`codexUsageData` via `resolve(_:)`, colored by percentage as before.
        for limitType in activeDisplayTypes where legacyLimitTypes.contains(limitType) {
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

    /// Build and draw the new account-driven points (P03): 2 per saved Claude account (5h outline,
    /// 7d filled) plus 1 for Codex's wrapped single-account snapshot (primary, outline). Both windows
    /// are skipped per-account/window when their `WindowUsage?` is nil, matching today's behavior of
    /// not showing a dot for a window with no data.
    private func drawAccountPoints(context: GraphicsContext, in rect: CGRect, drawnLabelRects: inout [CGRect]) {
        var points: [ResolvedPoint] = []

        for snapshot in claudeSnapshots {
            if let fiveHour = snapshot.fiveHour, activeDisplayTypes.contains(.fiveHour) {
                points.append(ResolvedPoint(
                    percentage: fiveHour.percentage,
                    resetsAt: fiveHour.resetsAt,
                    windowSeconds: fiveHour.windowSeconds,
                    color: snapshot.color.swiftUIColor,
                    accountId: snapshot.accountId,
                    markerStyle: .outline,
                    fallbackWindowSeconds: 5 * 3600
                ))
            }
            if let sevenDay = snapshot.sevenDay, activeDisplayTypes.contains(.sevenDay) {
                points.append(ResolvedPoint(
                    percentage: sevenDay.percentage,
                    resetsAt: sevenDay.resetsAt,
                    windowSeconds: sevenDay.windowSeconds,
                    color: snapshot.color.swiftUIColor,
                    accountId: snapshot.accountId,
                    markerStyle: .filled,
                    fallbackWindowSeconds: 7 * 24 * 3600
                ))
            }
        }

        if activeDisplayTypes.contains(.codexPrimary),
           let codexSnapshot = AccountUsageSnapshot.codexWrapper(from: codexUsageData, account: UserSettings.shared.currentCodexAccount),
           let primary = codexSnapshot.fiveHour,
           // Plottability guard (code-review fix, chart-only): when there's a reset time but no
           // known window length, we cannot compute a meaningful x-position. Skip only the chart
           // dot here — `codexWrapper` itself no longer applies this guard, so the legend row
           // (`PopoverLayout.legendItems`) still renders unconditionally.
           primary.resetsAt == nil || (primary.windowSeconds ?? 0) > 0 {
            points.append(ResolvedPoint(
                percentage: primary.percentage,
                resetsAt: primary.resetsAt,
                windowSeconds: primary.windowSeconds,
                color: codexSnapshot.color.swiftUIColor,
                accountId: codexSnapshot.accountId,
                markerStyle: .outline,
                // Codex must never guess a window length (code-review fix 3b): no fallback here.
                // `AccountUsageSnapshot.codexWrapper` already guarantees `windowSeconds` is known
                // whenever `resetsAt` is non-nil, so `calculateAccountElapsedRatio` never actually
                // needs this fallback for a Codex point — but it stays nil to make that explicit
                // rather than relying on `markerStyle` to infer provider.
                fallbackWindowSeconds: nil
            ))
        }

        if activeDisplayTypes.contains(.codexSecondary),
           let codexSnapshot = AccountUsageSnapshot.codexWrapper(from: codexUsageData, account: UserSettings.shared.currentCodexAccount),
           let secondary = codexSnapshot.sevenDay,
           // Plottability guard (code-review fix, chart-only): when there's a reset time but no
           // known window length, we cannot compute a meaningful x-position. Skip only the chart
           // dot here — `codexWrapper` itself no longer applies this guard, so the legend row
           // (`PopoverLayout.legendItems`) still renders unconditionally.
           secondary.resetsAt == nil || (secondary.windowSeconds ?? 0) > 0 {
            points.append(ResolvedPoint(
                percentage: secondary.percentage,
                resetsAt: secondary.resetsAt,
                windowSeconds: secondary.windowSeconds,
                color: codexSnapshot.color.swiftUIColor,
                accountId: codexSnapshot.accountId,
                markerStyle: .filled,
                // Codex must never guess a window length (code-review fix 3b): no fallback here.
                // `AccountUsageSnapshot.codexWrapper` already guarantees `windowSeconds` is known
                // whenever `resetsAt` is non-nil, so `calculateAccountElapsedRatio` never actually
                // needs this fallback for a Codex point — but it stays nil to make that explicit
                // rather than relying on `markerStyle` to infer provider.
                fallbackWindowSeconds: nil
            ))
        }

        for resolved in points {
            let xNormalized = calculateAccountElapsedRatio(
                resetsAt: resolved.resetsAt,
                windowSeconds: resolved.windowSeconds,
                fallbackWindowSeconds: resolved.fallbackWindowSeconds
            )
            let point = calculatePoint(percentage: resolved.percentage, xNormalized: xNormalized, in: rect)

            drawAccountDot(context: context, at: point, resolved: resolved)

            drawPercentageLabel(
                context: context,
                at: point,
                percentage: resolved.percentage,
                in: rect,
                drawnLabelRects: &drawnLabelRects
            )
        }
    }

    /// Draw a single account-driven marker: `.outline` (5h) is a stroked ring with no fill, `.filled`
    /// (7d) is a filled circle with a white border (same look as the legacy dot). Both get a red
    /// warning ring overlay on top when `UsageColorScheme.isNearLimit` — the overlay carries urgency,
    /// the base color still carries account identity (shared logic, coordinate with phase 05).
    private func drawAccountDot(context: GraphicsContext, at point: CGPoint, resolved: ResolvedPoint) {
        let dotRect = CGRect(
            x: point.x - dotRadius,
            y: point.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )

        switch resolved.markerStyle {
        case .outline:
            context.stroke(Circle().path(in: dotRect), with: .color(resolved.color), lineWidth: 2)
        case .filled, .legacy:
            context.fill(Circle().path(in: dotRect), with: .color(resolved.color))
            context.stroke(Circle().path(in: dotRect), with: .color(.white.opacity(0.8)), lineWidth: 1)
        }

        if UsageColorScheme.isNearLimit(percentage: resolved.percentage) {
            let overlayRect = dotRect.insetBy(dx: -2, dy: -2)
            context.stroke(Circle().path(in: overlayRect), with: .color(.red), lineWidth: 1.5)
        }
    }

    /// Elapsed-time ratio for account-driven points (P03 equivalent of `calculateElapsedTimeRatio`,
    /// which is keyed by `LimitType` and therefore unusable here). Falls back to the static 5h/7d
    /// window length — keyed by `markerStyle` rather than `LimitType` — only when `windowSeconds` is
    /// unknown, same convention as the legacy calculation.
    private func calculateAccountElapsedRatio(
        resetsAt: Date?,
        windowSeconds: TimeInterval?,
        fallbackWindowSeconds: TimeInterval?
    ) -> CGFloat {
        guard let resetsAt else { return 0 }

        let totalWindow: TimeInterval
        if let windowSeconds, windowSeconds > 0 {
            totalWindow = windowSeconds
        } else if let fallbackWindowSeconds, fallbackWindowSeconds > 0 {
            // Only Claude points carry a non-nil `fallbackWindowSeconds` (code-review fix 3b): their
            // 5h/7d windows really are fixed, unlike Codex's data-driven window length.
            totalWindow = fallbackWindowSeconds
        } else {
            // No real window and no justified fallback (Codex with an unknown window) — don't invent
            // a position; `AccountUsageSnapshot.codexWrapper` should already have kept this point from
            // being built at all, but return 0 rather than a fabricated x-position as a last resort.
            return 0
        }

        let remainingTime = resetsAt.timeIntervalSinceNow
        let elapsedTime = totalWindow - remainingTime
        let ratio = elapsedTime / totalWindow
        return CGFloat(max(0, min(1, ratio)))
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
            // Fallback only for Claude, whose windows really are a fixed 5h/7d. Codex windows are
            // data-driven: `limit_window_seconds` is optional on the wire, and guessing 5h for a
            // window that is actually 7 days pins the dot to the far right. `resolve(_:)` already
            // drops any Codex point with a known `resetsAt` but an unknown window, so the Codex
            // cases below are unreachable — they return 0 rather than invent a window length.
            switch limitType {
            case .fiveHour:
                totalWindow = 5 * 3600  // 5 hours in seconds
            case .sevenDay, .opusWeekly, .sonnetWeekly, .extraUsage:
                totalWindow = 7 * 24 * 3600  // 7 days in seconds
            case .codexPrimary, .codexSecondary, .codexExtraUsage:
                return 0
            }
            Logger.api.debug("LinearUsageGraphView: falling back to static window table for \(limitType.rawValue, privacy: .public) (windowSeconds was nil)")
        }

        let remainingTime = resetsAt.timeIntervalSinceNow
        let elapsedTime = totalWindow - remainingTime

        // Clamp to 0-1 range
        let ratio = elapsedTime / totalWindow
        return CGFloat(max(0, min(1, ratio)))
    }

    /// Whether a Codex window can be placed on the X axis at all.
    /// `limit_window_seconds` is optional on the wire; without it the elapsed-time ratio is unknowable
    /// for a window that has a reset time, and the old static 5h guess put the dot at the far right of
    /// a 7-day window. Dropping the point is honest; a wrong point is not. A window with no `resetsAt`
    /// is still plottable — it sits at x=0 by the same convention as `.extraUsage`, no window needed.
    private func isPlottable(_ limit: CodexUsageData.LimitData) -> Bool {
        limit.resetsAt == nil || (limit.windowSeconds ?? 0) > 0
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
                color: UsageColorScheme.fiveHourColorSwiftUI(limit.percentage),
                accountId: nil,
                markerStyle: .legacy,
                fallbackWindowSeconds: nil
            )
        case .sevenDay:
            guard let data = usageData, let limit = data.sevenDay else { return nil }
            return ResolvedPoint(
                percentage: limit.percentage,
                resetsAt: limit.resetsAt,
                windowSeconds: nil,
                color: UsageColorScheme.sevenDayColorSwiftUI(limit.percentage),
                accountId: nil,
                markerStyle: .legacy,
                fallbackWindowSeconds: nil
            )
        case .opusWeekly:
            guard let data = usageData, let limit = data.opus else { return nil }
            return ResolvedPoint(
                percentage: limit.percentage,
                resetsAt: limit.resetsAt,
                windowSeconds: nil,
                color: Color(UsageColorScheme.opusWeeklyColor(limit.percentage)),
                accountId: nil,
                markerStyle: .legacy,
                fallbackWindowSeconds: nil
            )
        case .sonnetWeekly:
            guard let data = usageData, let limit = data.sonnet else { return nil }
            return ResolvedPoint(
                percentage: limit.percentage,
                resetsAt: limit.resetsAt,
                windowSeconds: nil,
                color: Color(UsageColorScheme.sonnetWeeklyColor(limit.percentage)),
                accountId: nil,
                markerStyle: .legacy,
                fallbackWindowSeconds: nil
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
                color: Color(UsageColorScheme.extraUsageColor(percentage)),
                accountId: nil,
                markerStyle: .legacy,
                fallbackWindowSeconds: nil
            )
        case .codexPrimary:
            guard let limit = codexUsageData?.primary, isPlottable(limit) else { return nil }
            return ResolvedPoint(
                percentage: limit.percentage,
                resetsAt: limit.resetsAt,
                windowSeconds: limit.windowSeconds,
                color: UsageColorScheme.codexPrimaryColorSwiftUI(limit.percentage),
                accountId: nil,
                markerStyle: .legacy,
                fallbackWindowSeconds: nil
            )
        case .codexSecondary:
            // secondary_window is null on this account today (P01/P03 finding); guard makes that a
            // clean "no point drawn" rather than a fabricated dot at x=0,y=0.
            guard let limit = codexUsageData?.secondary, isPlottable(limit) else { return nil }
            return ResolvedPoint(
                percentage: limit.percentage,
                resetsAt: limit.resetsAt,
                windowSeconds: limit.windowSeconds,
                color: UsageColorScheme.codexSecondaryColorSwiftUI(limit.percentage),
                accountId: nil,
                markerStyle: .legacy,
                fallbackWindowSeconds: nil
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
                color: UsageColorScheme.codexExtraUsageColorSwiftUI(percentage),
                accountId: nil,
                markerStyle: .legacy,
                fallbackWindowSeconds: nil
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
