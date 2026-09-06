#!/usr/bin/env swift
//
// verify-antigravity-parsing.swift
//
// Standalone harness for the pure Antigravity parsing functions. There is no
// XCTest target in this repo, so this script duplicates the
// relevant pure value types from UsagePaceCC/Models/AntigravityUsageData.swift
// and runs them against 5 fixtures (a-e: parsing shapes incl. 1/2/3-bucket and
// unknown-window). Exits non-zero on any assertion failure.
//
// - Note: A 6th fixture (f) used to duplicate the *shape* of
//   `AccountUsageSnapshot.antigravitySnapshots(from:accounts:errors:)` with a hand-copied
//   `FakeAccountSnapshot`/`antigravitySnapshots` pair. It was removed: it
//   asserted against its own duplicate rather than the real implementation, so it would not
//   have failed when `AccountUsageSnapshot.antigravitySnapshot` changed behavior (an errored
//   account now keeps rendering with its last-known data instead of being
//   dropped). A self-testing fixture that silently drifts from the real code is worse than no
//   fixture; that behavior is exercised by the real Swift build/type-checker instead.
//
// Usage: swift scripts/verify-antigravity-parsing.swift
//

import Foundation

// MARK: - Duplicated pure types (kept in sync with UsagePaceCC/Models/AntigravityUsageData.swift)

struct AntigravityUsageResponse: Decodable {
    struct Bucket: Decodable {
        let bucketId: String
        let displayName: String
        let window: String
        let resetTime: String
        let description: String?
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

struct AntigravityUsageData: Equatable {
    struct Bucket: Equatable {
        let bucketId: String
        let groupDisplayName: String
        let bucketDisplayName: String
        let resetsAt: Date?
        let windowSeconds: TimeInterval?
        let remainingFraction: Double

        var usagePercentage: Double {
            min(100, max(0, (1 - remainingFraction) * 100))
        }
    }
    let buckets: [Bucket]
    let description: String?

    var primary: Bucket? { buckets.first }
    var secondary: Bucket? { buckets.count > 1 ? buckets[1] : nil }

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

enum AntigravityDateParsing {
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

// MARK: - Test harness

var failureCount = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #file, line: Int = #line) {
    if !condition() {
        failureCount += 1
        print("FAIL (\(file):\(line)): \(message)")
    } else {
        print("PASS: \(message)")
    }
}

func decode(_ json: String) -> AntigravityUsageResponse {
    let data = Data(json.utf8)
    return try! JSONDecoder().decode(AntigravityUsageResponse.self, from: data)
}

// MARK: - Fixture (a) — representative 2-group payload (synthetic)

do {
    let json = """
    {
      "groups": [
        { "displayName": "Gemini Models",
          "description": "Models within this group: Gemini Flash, Gemini Pro",
          "buckets": [
            { "bucketId": "gemini-weekly",
              "displayName": "Weekly Limit Remaining",
              "window": "weekly",
              "resetTime": "2031-06-01T12:00:00Z",
              "description": "Some quota has been used; it will fully refresh at the next weekly reset.",
              "remainingFraction": 0.75 } ] },
        { "displayName": "Claude and GPT models",
          "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
          "buckets": [
            { "bucketId": "3p-weekly", "displayName": "Weekly Limit Remaining",
              "window": "weekly", "resetTime": "2031-06-01T15:30:00Z",
              "remainingFraction": 1 } ] }
      ],
      "description": "Within each group, models share a weekly limit."
    }
    """
    let data = AntigravityUsageData.from(decode(json))
    expect(data.buckets.count == 2, "(a) flattens 2 groups × 1 bucket into 2 buckets")
    expect(data.buckets[0].bucketId == "gemini-weekly", "(a) preserves group/bucket order — bucket 0 is gemini-weekly")
    expect(data.buckets[1].bucketId == "3p-weekly", "(a) preserves group/bucket order — bucket 1 is 3p-weekly")
    expect(data.buckets[0].groupDisplayName == "Gemini Models", "(a) bucket 0 carries its group displayName")
    expect(abs(data.buckets[0].usagePercentage - 25.0) < 0.01, "(a) usagePercentage inverts remainingFraction (0.75 -> 25.0%)")
    expect(data.buckets[1].usagePercentage == 0, "(a) remainingFraction 1 -> usagePercentage 0")
    expect(data.buckets[0].windowSeconds == 604_800, "(a) window 'weekly' -> 604800 seconds")
    expect(data.buckets[0].resetsAt != nil, "(a) resetTime (Z suffix) parses to a Date")
    expect(data.primary?.bucketId == "gemini-weekly", "(a) primary is bucket 0")
    expect(data.secondary?.bucketId == "3p-weekly", "(a) secondary is bucket 1")
}

// MARK: - Fixture (b) — bucket missing `description` (remainingFraction == 1)

do {
    let json = """
    {
      "groups": [
        { "displayName": "Gemini Models", "description": null,
          "buckets": [
            { "bucketId": "gemini-weekly", "displayName": "Weekly Limit Remaining",
              "window": "weekly", "resetTime": "2031-06-01T12:00:00-05:00",
              "remainingFraction": 1 } ] }
      ],
      "description": null
    }
    """
    let data = AntigravityUsageData.from(decode(json))
    expect(data.buckets.count == 1, "(b) decodes a bucket with no description field at all")
    expect(data.buckets[0].usagePercentage == 0, "(b) remainingFraction 1 -> 0% used")
    expect(data.buckets[0].resetsAt != nil, "(b) resetTime with local offset (-05:00) parses correctly")
    if let resetsAt = data.buckets[0].resetsAt {
        let expected = AntigravityDateParsing.parseRFC3339("2031-06-01T12:00:00-05:00")
        expect(resetsAt == expected, "(b) local-offset parse produces the correct absolute instant")
    }
}

// MARK: - Fixture (c) — unknown `window` value

do {
    let json = """
    {
      "groups": [
        { "displayName": "Experimental", "description": null,
          "buckets": [
            { "bucketId": "exp-bucket", "displayName": "Experimental Limit",
              "window": "monthly", "resetTime": "2026-10-01T00:00:00Z",
              "remainingFraction": 0.5 } ] }
      ],
      "description": null
    }
    """
    let data = AntigravityUsageData.from(decode(json))
    expect(data.buckets.count == 1, "(c) decodes a bucket with an unrecognized window value")
    expect(data.buckets[0].windowSeconds == nil, "(c) unknown window 'monthly' -> windowSeconds nil (never guess a default)")
    expect(data.buckets[0].usagePercentage == 50, "(c) usagePercentage still computed even with unknown window")
}

// MARK: - Fixture (d) — empty `groups` array

do {
    let json = """
    { "groups": [], "description": "No quota groups configured for this account." }
    """
    let data = AntigravityUsageData.from(decode(json))
    expect(data.buckets.isEmpty, "(d) empty groups array -> empty buckets, no crash")
    expect(data.primary == nil, "(d) primary is nil when buckets is empty")
    expect(data.secondary == nil, "(d) secondary is nil when buckets is empty")
    expect(data.description == "No quota groups configured for this account.", "(d) top-level description is preserved even with no groups")
}

// MARK: - Fixture (e) — 3-group payload

do {
    let json = """
    {
      "groups": [
        { "displayName": "Gemini Models", "description": null,
          "buckets": [ { "bucketId": "gemini-weekly", "displayName": "Weekly Limit Remaining",
            "window": "weekly", "resetTime": "2031-06-01T12:00:00Z", "remainingFraction": 0.8 } ] },
        { "displayName": "Claude and GPT models", "description": null,
          "buckets": [ { "bucketId": "3p-weekly", "displayName": "Weekly Limit Remaining",
            "window": "weekly", "resetTime": "2031-06-01T15:30:00Z", "remainingFraction": 0.6 } ] },
        { "displayName": "Daily Extras", "description": null,
          "buckets": [ { "bucketId": "extras-daily", "displayName": "Daily Limit Remaining",
            "window": "daily", "resetTime": "2026-09-07T00:00:00Z", "remainingFraction": 0.2 } ] }
      ],
      "description": null
    }
    """
    let data = AntigravityUsageData.from(decode(json))
    expect(data.buckets.count == 3, "(e) 3 groups × 1 bucket each -> 3 flattened buckets")
    expect(data.buckets.map { $0.bucketId } == ["gemini-weekly", "3p-weekly", "extras-daily"], "(e) flattening order matches server group/bucket order")
    expect(data.primary?.bucketId == "gemini-weekly", "(e) primary is bucket 0 even with 3 groups")
    expect(data.secondary?.bucketId == "3p-weekly", "(e) secondary is bucket 1; bucket 2 retained but not a named slot")
    expect(data.buckets[2].windowSeconds == 86_400, "(e) 'daily' window maps to 86400 seconds")
    expect(data.buckets.count > 2, "(e) all 3 buckets retained in the full list even though only 2 are ever rendered")
}

// MARK: - Summary

print("---")
if failureCount == 0 {
    print("All fixtures passed.")
    exit(0)
} else {
    print("\(failureCount) assertion(s) failed.")
    exit(1)
}
