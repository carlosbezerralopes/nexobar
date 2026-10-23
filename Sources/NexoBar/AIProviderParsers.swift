// Adapted from Codenotch MIT, revision 1a33306a; see THIRD_PARTY_NOTICES.md.
import Foundation

// MARK: - CursorUsage

/// Parses Cursor's `GET /api/usage-summary`, recorded from a live free account:
///
/// ```json
/// { "billingCycleStart": "2026-08-24T03:32:15.933Z",
///   "billingCycleEnd":   "2026-09-24T03:32:15.933Z",
///   "membershipType": "free", "isUnlimited": false,
///   "individualUsage": {
///     "plan": { "enabled": true, "used": 0, "limit": 0, "remaining": 0,
///               "breakdown": { "included": 0, "bonus": 19, "total": 19 },
///               "autoPercentUsed": 0, "apiPercentUsed": 19,
///               "totalPercentUsed": 9.5 },
///     "onDemand": { "enabled": false, "used": 0, "limit": null } } }
/// ```
///
/// Enterprise / team plans ship a different shape — no `plan` percentages,
/// just a hard `overall` ceiling:
///
/// ```json
/// { "membershipType": "enterprise", "limitType": "team",
///   "individualUsage": {
///     "overall": { "enabled": true, "used": 6907, "limit": 45000, "remaining": 38093 } },
///   "teamUsage": {
///     "onDemand": { "enabled": true, "used": 0, "limit": 1000000 } } }
/// ```
///
/// Cursor meters an **allowance, not a request count**. Plan & Usage has two
/// bars. The ring follows **Auto** (`autoPercentUsed`) — Cursor Models,
/// Grok, Composer. API (`apiPercentUsed`) is a separate bucket.
/// `totalPercentUsed` is a blend of the two and is not a row here.
///
/// The `used`/`limit` pair sits at zero on a free plan even while real usage
/// is happening, because the allowance arrives as `breakdown.bonus` rather
/// than as a dollar limit. Reading those reported 0% for an account that was
/// actually on the Cursor Models bar, which is exactly what this parser
/// used to do. Enterprise is the opposite: there is no percentage field, so
/// `used`/`limit` on `overall` is the reading.
enum CursorUsage {
    static var modelsLabel: String { L10n.t("Auto usage") }

    /// The window the ring should mean. Cursor Models when that field exists,
    /// never the blended total, never API — and on an enterprise/team plan,
    /// which reports neither, the hard `included` ceiling.
    static func plan(fromJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (root["membershipType"] as? String)?.nonEmptyPlan
    }

    static func headlineID(in windows: [LimitWindow]) -> String {
        if windows.contains(where: { $0.id == "auto" }) { return "auto" }
        if windows.contains(where: { $0.id == "included" }) { return "included" }
        return "api"
    }

    static func windows(fromJSON json: String) throws -> [LimitWindow] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        let resetsAt = date(root["billingCycleEnd"])
        let duration = date(root["billingCycleStart"]).flatMap { start in
            resetsAt.map { $0.timeIntervalSince(start) }
        }
        let usage = root["individualUsage"] as? [String: Any] ?? [:]
        let plan = usage["plan"] as? [String: Any] ?? [:]
        let team = root["teamUsage"] as? [String: Any] ?? [:]

        var windows: [LimitWindow] = []

        // Zero is a reading, not an absence — a fresh month is 0% on this bar.
        if let models = percent(plan["autoPercentUsed"]) {
            windows.append(LimitWindow(id: "auto", label: modelsLabel,
                                       usedFraction: models, resetsAt: resetsAt,
                                       duration: duration))
        }
        if let api = percent(plan["apiPercentUsed"]), api > 0 {
            windows.append(LimitWindow(id: "api", label: L10n.t("API usage"),
                                       usedFraction: api, resetsAt: resetsAt,
                                       duration: duration))
        }
        if let onDemand = spendWindow(usage["onDemand"], id: "on_demand",
                                      label: L10n.t("On demand"), resetsAt: resetsAt,
                                      duration: duration) {
            windows.append(onDemand)
        }

        // Enterprise / team plans omit `plan` entirely and meter a hard
        // `overall` ceiling instead. Keep the window id as `included` so the
        // provider's headlineID still resolves.
        if windows.isEmpty,
           let overall = spendWindow(usage["overall"], id: "included",
                                     label: L10n.t("Included usage"), resetsAt: resetsAt,
                                     duration: duration) {
            windows.append(overall)
        }
        if let teamOnDemand = spendWindow(team["onDemand"], id: "team_on_demand",
                                          label: L10n.t("Team on demand"), resetsAt: resetsAt,
                                          duration: duration),
           (teamOnDemand.usedFraction ?? 0) > 0 {
            windows.append(teamOnDemand)
        }

        guard windows.isEmpty else { return windows }

        let membership = (root["membershipType"] as? String) ?? "this"
        if (root["isUnlimited"] as? Bool) == true {
            throw UsageProviderError.nothingMetered(L10n.t("Unlimited on the \(membership) plan — nothing to meter"))
        }
        throw UsageProviderError.nothingMetered(L10n.t("The \(membership) plan has nothing for Cursor to meter yet"))
    }

    /// A dollar-denominated bucket, used where a plan states a real ceiling.
    private static func spendWindow(
        _ any: Any?, id: String, label: String, resetsAt: Date?, duration: TimeInterval?
    ) -> LimitWindow? {
        guard let bucket = any as? [String: Any],
              (bucket["enabled"] as? Bool) == true,
              let limit = AIUsageParser.number(bucket["limit"]), limit > 0,
              let used = AIUsageParser.number(bucket["used"])
        else { return nil }
        return LimitWindow(id: id, label: label, usedFraction: used / limit,
                           resetsAt: resetsAt, duration: duration)
    }

    /// Cursor reports 0–100; the rest of the app works in 0–1.
    private static func percent(_ any: Any?) -> Double? {
        guard let number = AIUsageParser.number(any) else { return nil }
        return number / 100
    }

    private static func date(_ any: Any?) -> Date? {
        guard let text = any as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

// MARK: - GrokUsage

/// Parses Grok CLI's billing endpoints, recorded from a live SuperGrok session:
///
/// `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
/// ```json
/// { "config": {
///     "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
///                        "start": "2026-09-05T08:21:18.802818+00:00",
///                        "end":   "2026-09-12T08:21:18.802818+00:00" },
///     "creditUsagePercent": 8.0,
///     "productUsage": [{ "product": "GrokBuild", "usagePercent": 8.0 }],
///     "billingPeriodStart": "2026-09-05T08:21:18.802818+00:00",
///     "billingPeriodEnd":   "2026-09-12T08:21:18.802818+00:00" } }
/// ```
///
/// The credits payload is the ring: a weekly Grok Build allowance. Grok's own
/// account charge date is not in this response — the unformatted `/billing`
/// payload's `billingPeriodEnd` is a calendar-month usage ledger, not a bill,
/// and nothing here says which day of the month an account is actually
/// charged. Showing one would mean guessing at a fact this endpoint does not
/// state.
enum GrokUsage {
    static func windows(creditsJSON: String) throws -> [LimitWindow] {
        guard let credits = object(creditsJSON)?["config"] as? [String: Any] else {
            throw UsageProviderError.badResponse(status: 0)
        }

        var windows: [LimitWindow] = []

        let currentPeriod = period(credits["currentPeriod"])
        let currentEnd = date(currentPeriod?["end"])
        let creditsReset = currentEnd ?? date(credits["billingPeriodEnd"])
        let start = currentEnd == nil
            ? date(credits["billingPeriodStart"]) : date(currentPeriod?["start"])
        let duration = start.flatMap { start in creditsReset.map { $0.timeIntervalSince(start) } }

        if let fraction = percent(credits["creditUsagePercent"]) {
            windows.append(LimitWindow(
                id: "credits",
                label: productLabel(credits) ?? L10n.t("Grok Build"),
                usedFraction: fraction,
                resetsAt: creditsReset,
                duration: duration
            ))
        } else if let products = credits["productUsage"] as? [[String: Any]] {
            for product in products {
                guard let fraction = percent(product["usagePercent"]) else { continue }
                let name = (product["product"] as? String).map(humanize) ?? L10n.t("Usage")
                // The ring is declared as `headlineID: "credits"`. Using the
                // wire product name here left a valid bar in the tooltip and
                // a dash on the cell.
                windows.append(LimitWindow(
                    id: windows.isEmpty ? "credits" : ((product["product"] as? String) ?? name),
                    label: name,
                    usedFraction: fraction,
                    resetsAt: creditsReset,
                    duration: duration
                ))
            }
        }

        // A weekly plan pool (X Premium+, SuperGrok) states its window in
        // `currentPeriod` and omits `creditUsagePercent`/`productUsage` until
        // usage lands, so the branches above find nothing on a fresh period.
        // Grok's own `/usage` still shows this as a "Weekly limit" bar at 0%
        // with the period end as the reset, so mirror it rather than reporting
        // the account as unmetered.
        if windows.isEmpty,
           let weekly = period(credits["currentPeriod"]),
           (weekly["type"] as? String).map({ $0.contains("WEEKLY") }) == true {
            windows.append(LimitWindow(
                id: "credits",
                label: L10n.t("Weekly limit"),
                usedFraction: 0,
                resetsAt: date(weekly["end"]) ?? creditsReset
            ))
        }

        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered(L10n.t("Grok has nothing metered on this account yet"))
        }
        return windows
    }

    private static func productLabel(_ credits: [String: Any]) -> String? {
        guard let products = credits["productUsage"] as? [[String: Any]],
              let name = products.first?["product"] as? String
        else { return nil }
        return humanize(name)
    }

    /// "GrokBuild" → "Grok Build". The wire name is one word; the usage modal
    /// writes two.
    static func humanize(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isUppercase, !result.isEmpty { result.append(" ") }
            result.append(character)
        }
        return result
    }

    private static func percent(_ any: Any?) -> Double? {
        guard let number = AIUsageParser.number(any) else { return nil }
        return number / 100
    }

    private static func period(_ any: Any?) -> [String: Any]? {
        any as? [String: Any]
    }

    private static func object(_ json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func date(_ any: Any?) -> Date? {
        AIUsageParser.date(any)
    }
}

// MARK: - OpenCodeUsage

/// Parses `GET https://opencode.ai/zen/go/v1/usage`.
///
/// The account-wide Go plan windows, the same figures the OpenCode dashboard
/// shows — recorded live (secret redacted):
///
/// ```json
/// {"usage":{
///   "rolling":{"status":"ok","percent":0,"resetsAt":"2026-09-06T12:31:06.611Z"},
///   "weekly": {"status":"ok","percent":0,"resetsAt":"2026-09-07T00:00:00.611Z"},
///   "monthly":{"status":"ok","percent":0,"resetsAt":"2026-10-03T13:09:45.611Z"}}}
/// ```
///
/// `percent` is *used*, matching the dashboard's "X% used" — the ring needs no
/// inversion. `resetsAt` carries milliseconds, which the plain ISO8601
/// formatter refuses to read, so both fractional and plain forms are tried.
enum OpenCodeUsage {
    /// The Go plan's API key. This is the route the key is for.
    static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    /// The same figures for an OAuth sign-in — the `inference/` routes OpenCode
    /// itself uses once signed in. The pairing is not interchangeable:
    /// `zen/go` answers an OAuth token 401 even on an account that has Go, and
    /// `inference/go` answers a Go key the same way. Both 401s are
    /// indistinguishable from "no Go plan", so sending the wrong one reads as
    /// a signed-out app rather than as a bug. See `OpenCodeProvider`.
    static let oauthEndpoint = URL(string: "https://opencode.ai/inference/go/v1/usage")!
    /// Where an OAuth sign-in's `metadata.server` points when it names none.
    static let defaultConsole = URL(string: "https://opencode.ai/console")!

    /// Window ids in headline order. The ring means the rolling window — the
    /// current one, the same subject Claude's session and Codex's primary are.
    private static var windows: [(id: String, label: String)] {
        [
            ("rolling", L10n.t("5h limit")),
            ("weekly", L10n.t("Weekly limit")),
            ("monthly", L10n.t("Monthly limit")),
        ]
    }

    static func windows(fromJSON json: String, now: Date = Date()) throws -> [LimitWindow] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        let out = self.windows.compactMap { id, label -> LimitWindow? in
            guard let entry = usage[id] as? [String: Any],
                  let percent = AIUsageParser.number(entry["percent"])
            else { return nil }
            let resetsAt = (entry["resetsAt"] as? String).flatMap(date(from:))
            return LimitWindow(
                id: id,
                label: label,
                usedFraction: percent / 100,
                resetsAt: resetsAt,
                duration: duration(for: id, endingAt: resetsAt)
            )
        }
        guard !out.isEmpty else { throw UsageProviderError.badResponse(status: 0) }
        return out
    }

    private static func date(from stamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: stamp) { return date }
        return ISO8601DateFormatter().date(from: stamp)
    }

    private static func duration(for id: String, endingAt reset: Date?) -> TimeInterval? {
        if id == "rolling" { return 5 * 3600 }
        if id == "weekly" { return 7 * 86400 }
        guard id == "monthly", let reset else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .month, value: -1, to: reset)
            .map { reset.timeIntervalSince($0) }
    }
}

// MARK: - GLMUsage

/// Parses the answer from Z.ai's own usage monitor,
/// `GET /api/monitor/usage/quota/limit`.
///
/// The Coding Plan does not meter tokens the way Anthropic meters prompts — it
/// reports three separate allowances in one response, and the window each
/// token limit belongs to is encoded rather than named:
///
/// ```json
/// { "code": 200, "success": true,
///   "data": { "level": "pro",
///     "limits": [
///       { "type": "TOKENS_LIMIT", "unit": 3, "number": 5,
///         "percentage": 12.5, "currentValue": 1250000, "usage": 12000000,
///         "nextResetTime": 1788682200000 },
///       { "type": "TOKENS_LIMIT", "unit": 6, "number": 1,
///         "percentage": 8.1, "nextResetTime": 1789190400000 },
///       { "type": "TIME_LIMIT", "percentage": 4.0,
///         "currentValue": 40, "usage": 1000 } ] } }
/// ```
///
/// `unit`/`number` pair up as (hours, 5) for the rolling session and
/// (weeks, 1) for the weekly allowance; `TIME_LIMIT` is the monthly MCP call
/// budget. What is being metered inside a window varies by plan — token plans
/// answer `TOKENS_LIMIT`, credit plans `CREDIT_LIMIT` — and both pair the
/// window length with the same `unit`/`number`, so it is the length the
/// identity is built from, not the meter. The shape is pinned by tests,
/// including a response recorded from a live credit plan: the endpoint is not
/// a published API, and this is the first place a change would show.
///
/// Two things about this endpoint differ from the others here, and both are
/// load-bearing. Errors ride in under an HTTP 200 — `{ "code": 401, "success":
/// false }` is what an expired token looks like on the wire — so the envelope
/// is read before the payload is trusted. And the MCP row never carries a
/// reset time, so unlike Claude's windows a row is not dropped for lacking
/// one; a percentage with no countdown is still a reading.
enum GLMUsage {
    struct Payload {
        /// The plan's own name for itself, lowercase — "pro", "max". Nil when
        /// the response declines to say.
        let level: String?
        let windows: [LimitWindow]
    }

    /// The envelope plus payload shape.
    struct Response: Decodable {
        struct Limit: Decodable {
            let type: String?
            let unit: Int?
            let number: Int?
            let percentage: Double?
            let currentValue: Double?
            let usage: Double?
            let total: Double?
            /// Milliseconds since the epoch, not seconds — the one unit this
            /// API shares with JavaScript rather than with Unix.
            let nextResetTime: Double?
        }
        struct Data: Decodable {
            let level: String?
            let limits: [Limit]?
        }

        let code: Int?
        let success: Bool?
        let msg: String?
        let data: Data?
    }

    /// True only when the envelope says the request itself succeeded.
    static func succeeded(_ response: Response) -> Bool {
        (response.success ?? false) || response.code == nil || response.code == 200
    }

    /// The failure the envelope describes, if it describes one.
    static func failure(in response: Response) -> UsageProviderError? {
        guard !succeeded(response) else { return nil }
        switch response.code {
        case 401, 403: return .needsAuth
        case 429:      return .rateLimited(retryAfter: 0)
        case .some(let code): return .badResponse(status: code)
        case nil:      return .badResponse(status: 200)
        }
    }

    static func parse(_ data: Data) throws -> Payload {
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let failure = failure(in: response) { throw failure }
        return Payload(level: response.data?.level,
                       windows: windows(in: response.data?.limits ?? []))
    }

    /// Turns the limits array into limit windows, session first.
    static func windows(in limits: [Response.Limit]) -> [LimitWindow] {
        limits.compactMap { window(for: $0) }.sorted(by: Self.displayOrder)
    }

    private static func window(for limit: Response.Limit) -> LimitWindow? {
        // Without a percentage there is nothing to draw: a bare count from an
        // unnamed allowance would be a reading we invented a scale for.
        guard let percentage = limit.percentage else { return nil }

        return LimitWindow(
            id: Self.id(for: limit),
            label: Self.label(for: limit),
            usedFraction: percentage / 100,
            resetsAt: limit.nextResetTime.map { Date(timeIntervalSince1970: $0 / 1000) },
            duration: limit.number.flatMap { number in
                switch limit.unit {
                case 3: return Double(number) * 3600
                case 6: return Double(number) * 7 * 86400
                default: return nil
                }
            }
        )
    }

    /// Which window this is, encoded in `unit`/`number`.
    ///
    /// (hours, 5) is the rolling session — the Coding Plan's "next 5-hour
    /// cycle" — and (weeks, 1) the weekly allowance. The *type* token is
    /// deliberately not part of the identity: token plans answer
    /// `TOKENS_LIMIT`, credit plans answer `CREDIT_LIMIT`, and both encode the
    /// window length the same way. `TIME_LIMIT` is the monthly MCP budget and
    /// carries no unit/number at all.
    static func id(for limit: Response.Limit) -> String {
        switch limit.type {
        case "TIME_LIMIT":
            return "mcp"
        default:
            switch (limit.unit, limit.number) {
            case (3?, 5?):    return "session"
            case (6?, 1?):    return "weekly"
            case (.some(let unit), .some(let number)):
                return "window-\(unit)x\(number)"
            default:
                return limit.type?.lowercased() ?? "unknown"
            }
        }
    }

    /// The frame's wording, for the windows it knows.
    static func label(for limit: Response.Limit) -> String {
        switch id(for: limit) {
        case "session": return L10n.t("Current session")
        case "weekly":  return L10n.t("Weekly")
        case "mcp":     return L10n.t("MCP (1 month)")
        case let id     where id.hasPrefix("window-"):
            switch (limit.unit, limit.number) {
            case (3?, .some(let number)): return L10n.t("Usage (\(number) h)")
            case (6?, .some(let number)): return L10n.t("Usage (\(number) wk)")
            default:                      return L10n.t("Usage")
            }
        default:        return L10n.t("Usage")
        }
    }

    /// Session first, then weekly, then MCP — the order the plan's own panel
    /// leads with.
    private static func displayOrder(_ a: LimitWindow, _ b: LimitWindow) -> Bool {
        func rank(_ id: String) -> Int {
            switch id {
            case "session": return 0
            case "weekly":  return 1
            case "mcp":     return 2
            default:        return 3
            }
        }
        let (ra, rb) = (rank(a.id), rank(b.id))
        return ra == rb ? a.id < b.id : ra < rb
    }
}

// MARK: - AntigravityQuotaParser

/// Normalizes the quota envelopes shared by Antigravity's local language server
/// and Cloud Code. Keeping this outside either transport prevents source-specific
/// window IDs, cadence inference, or ordering from leaking into the UI.
enum AntigravityQuotaParser {
    private struct Remaining: Decodable {
        let fraction: Double?

        private enum CodingKeys: String, CodingKey {
            case remainingFraction
            case oneofCase = "case"
            case value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let fraction = try container.decodeIfPresent(Double.self, forKey: .remainingFraction) {
                self.fraction = fraction
            } else if try container.decodeIfPresent(String.self, forKey: .oneofCase) == "remainingFraction" {
                self.fraction = try container.decodeIfPresent(Double.self, forKey: .value)
            } else {
                self.fraction = nil
            }
        }
    }

    private struct Bucket: Decodable {
        let modelId: String?
        let bucketId: String?
        let name: String?
        let displayName: String?
        let remainingFraction: Double?
        let remaining: Remaining?
        let used: Double?
        let limit: Double?
        let resetTime: String?
        let window: String?
        let disabled: Bool?

        var fraction: Double? { self.remainingFraction ?? self.remaining?.fraction }
    }

    private struct Group: Decodable {
        let displayName: String?
        let buckets: [Bucket]?
    }

    private struct GroupBody: Decodable {
        let groups: [Group]?
    }

    private struct Response: Decodable {
        let buckets: [Bucket]?
        let groups: [Group]?
        let quotaGroups: [Group]?
        let response: GroupBody?
        let summary: GroupBody?
    }

    private struct Candidate {
        let remaining: Double
        let resetDate: Date?
        let isWeekly: Bool
    }

    static func parse(_ data: Data, now: Date) -> [LimitWindow] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        let groups = response.response?.groups
            ?? response.summary?.groups
            ?? response.groups
            ?? response.quotaGroups
            ?? []
        if !groups.isEmpty { return self.groupedWindows(groups) }
        guard let buckets = response.buckets, !buckets.isEmpty else { return [] }
        if buckets.contains(where: { $0.limit != nil }) {
            return self.legacyWindows(buckets)
        }
        return self.modelWindows(buckets, now: now)
    }

    private static func groupedWindows(_ groups: [Group]) -> [LimitWindow] {
        let sortedGroups = groups.enumerated().sorted { lhs, rhs in
            let lhsRank = self.groupRank(lhs.element.displayName)
            let rhsRank = self.groupRank(rhs.element.displayName)
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }
        var windows: [LimitWindow] = []
        for indexedGroup in sortedGroups {
            windows.append(contentsOf: self.bucketWindows(in: indexedGroup.element))
        }
        return windows
    }

    private static func bucketWindows(in group: Group) -> [LimitWindow] {
        let sortedBuckets = (group.buckets ?? []).enumerated().sorted { lhs, rhs in
            let lhsRank = self.cadence(lhs.element)
            let rhsRank = self.cadence(rhs.element)
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }
        return sortedBuckets.compactMap { indexedBucket in
            let bucket = indexedBucket.element
            guard bucket.disabled != true else { return nil }
            let groupName = group.displayName
            let rawID = self.id(for: bucket, group: groupName)
            let reset = bucket.resetTime.flatMap(AntigravityCredentials.parse)
            if let remaining = bucket.fraction, (0...1).contains(remaining) {
                return LimitWindow(
                    id: rawID,
                    group: groupName?.isEmpty == false ? groupName : nil,
                    label: self.label(for: bucket, fallback: "Usage"),
                    usedFraction: 1 - remaining,
                    resetsAt: reset,
                    duration: self.duration(for: bucket))
            }
            guard let limit = bucket.limit, limit > 0,
                  let used = bucket.used, used >= 0, used <= limit * 1.5
            else { return nil }
            return LimitWindow(
                id: rawID,
                group: groupName?.isEmpty == false ? groupName : nil,
                label: self.label(for: bucket, fallback: rawID),
                usedFraction: used / limit,
                resetsAt: reset,
                duration: self.duration(for: bucket))
        }
    }

    private static func legacyWindows(_ buckets: [Bucket]) -> [LimitWindow] {
        buckets.compactMap { bucket in
            guard let limit = bucket.limit, limit > 0,
                  let used = bucket.used, used >= 0, used <= limit * 1.5
            else { return nil }
            let rawID = self.id(for: bucket, group: nil)
            return LimitWindow(
                id: rawID,
                label: self.label(for: bucket, fallback: rawID),
                usedFraction: used / limit,
                resetsAt: bucket.resetTime.flatMap(AntigravityCredentials.parse),
                duration: self.duration(for: bucket))
        }
    }

    private static func modelWindows(_ buckets: [Bucket], now: Date) -> [LimitWindow] {
        var geminiHourly: [Candidate] = []
        var geminiWeekly: [Candidate] = []
        var thirdPartyHourly: [Candidate] = []
        var thirdPartyWeekly: [Candidate] = []

        for bucket in buckets {
            guard let remaining = bucket.fraction, (0...1).contains(remaining) else { continue }
            let model = self.normalized(self.id(for: bucket, group: nil))
            guard !model.isEmpty, !model.starts(with: "chat_") else { continue }
            let resetDate = bucket.resetTime.flatMap(AntigravityCredentials.parse)
            let resetIsWeekly: Bool
            if let resetDate {
                resetIsWeekly = resetDate.timeIntervalSince(now) > 24 * 3600
            } else {
                resetIsWeekly = false
            }
            let isWeekly = self.cadence(bucket) == 1 || resetIsWeekly
            let candidate = Candidate(remaining: remaining, resetDate: resetDate, isWeekly: isWeekly)
            if model.contains("gemini") {
                if isWeekly { geminiWeekly.append(candidate) } else { geminiHourly.append(candidate) }
            } else if model.contains("claude") || model.contains("gpt") || model.contains("openai") {
                if isWeekly { thirdPartyWeekly.append(candidate) } else { thirdPartyHourly.append(candidate) }
            }
        }

        var windows: [LimitWindow] = []
        if let window = self.aggregate(
            geminiHourly, id: "gemini-hourly", group: "Gemini Models", label: "5-hour Limit", weekly: false)
        {
            windows.append(window)
        }
        if let window = self.aggregate(
            geminiWeekly, id: "gemini-weekly", group: "Gemini Models", label: L10n.t("Weekly Limit"), weekly: true)
        {
            windows.append(window)
        }
        if let window = self.aggregate(
            thirdPartyHourly, id: "3p-hourly", group: "Claude and GPT models", label: "5-hour Limit", weekly: false)
        {
            windows.append(window)
        }
        if let window = self.aggregate(
            thirdPartyWeekly, id: "3p-weekly", group: "Claude and GPT models", label: L10n.t("Weekly Limit"), weekly: true)
        {
            windows.append(window)
        }
        return windows
    }

    private static func aggregate(
        _ candidates: [Candidate],
        id: String,
        group: String,
        label: String,
        weekly: Bool) -> LimitWindow?
    {
        guard let best = candidates.min(by: { $0.remaining < $1.remaining }) else { return nil }
        return LimitWindow(
            id: id,
            group: group,
            label: label,
            usedFraction: 1 - best.remaining,
            resetsAt: best.resetDate,
            duration: weekly ? 7 * 86400 : 5 * 3600)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func groupRank(_ value: String?) -> Int {
        let normalized = self.normalized(value ?? "")
        if normalized.contains("gemini") { return 0 }
        if normalized.contains("claude") || normalized.contains("gpt") { return 1 }
        return 2
    }

    private static func cadence(_ bucket: Bucket) -> Int {
        if let value = self.cadenceValue(bucket.window), self.isWeeklyValue(value) { return 1 }
        if let value = self.cadenceValue(bucket.bucketId), self.isWeeklyValue(value) { return 1 }
        if let value = self.cadenceValue(bucket.displayName), self.isWeeklyValue(value) { return 1 }
        if let value = self.cadenceValue(bucket.window), self.isSessionValue(value) { return 0 }
        if let value = self.cadenceValue(bucket.bucketId), self.isSessionValue(value) { return 0 }
        if let value = self.cadenceValue(bucket.displayName), self.isSessionValue(value) { return 0 }
        return 2
    }

    private static func cadenceValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = self.normalized(raw)
        guard !value.isEmpty else { return nil }
        return value.hasSuffix(" limit") ? String(value.dropLast(" limit".count)) : value
    }

    private static func isWeeklyValue(_ value: String) -> Bool {
        value == "weekly" || value.hasSuffix("-weekly") || value.hasSuffix(" weekly")
    }

    private static func isSessionValue(_ value: String) -> Bool {
        value == "session" || value == "5h" || value == "5-hour" ||
            value == "five hour" || value == "five-hour" || value == "hourly" ||
            value.hasSuffix("-session") || value.hasSuffix("-5h") ||
            value.hasSuffix("-5-hour") || value.hasSuffix("-five-hour") ||
            value.hasSuffix("-hourly")
    }

    private static func duration(for bucket: Bucket) -> TimeInterval? {
        switch self.cadence(bucket) {
        case 0: return 5 * 3600
        case 1: return 7 * 86400
        default: return nil
        }
    }

    private static func label(for bucket: Bucket, fallback: String) -> String {
        var value = bucket.displayName ?? fallback
        if value.hasSuffix(" Remaining") {
            value = String(value.dropLast(" Remaining".count))
        }
        return value == "Five Hour Limit" ? "5-hour Limit" : value
    }

    private static func id(for bucket: Bucket, group: String?) -> String {
        [bucket.bucketId, bucket.modelId, bucket.name, group]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .first ?? "quota"
    }
}

// MARK: - KiroLimits

/// Offline fixture parser for the GetUsageLimits CREDIT row. Runtime uses only the CLI.
/// Total usage includes overage; subtract it before displaying the plan bucket.
enum KiroLimits {
    struct CreditLimits: Equatable {
        var planUsed: Double
        var planLimit: Double
        var overageUsed: Double
        var overageCap: Double?
        var overageEnabled: Bool?
        var overageCharges: Double?
        var resetAt: Date?
        var hasUnseparatedBonus: Bool
    }

    static func parse(_ data: Data) throws -> CreditLimits {
        let response: UsageLimitsResponse
        do {
            response = try JSONDecoder().decode(UsageLimitsResponse.self, from: data)
        } catch {
            throw UsageProviderError.badResponse(status: 0)
        }

        let credits = response.usageBreakdownList.filter { $0.resourceType == "CREDIT" }
        guard let credit = credits.first else {
            throw UsageProviderError.badResponse(status: 0)
        }
        // Two CREDIT rows leave no single authoritative ceiling.
        guard credits.count == 1 else {
            throw UsageProviderError.badResponse(status: 0)
        }

        guard let planLimitRaw = firstNumber(
            credit.usageLimitWithPrecision, credit.usageLimit
        ), let totalRaw = firstNumber(
            credit.currentUsageWithPrecision, credit.currentUsage
        ) else {
            throw UsageProviderError.badResponse(status: 0)
        }
        let planLimit = try usable(planLimitRaw)
        let totalUsed = try usable(totalRaw)
        // Prefer the precise overage; the integer field is what some
        // payloads send alone. Defaulting a missing overage to 0 would
        // count overage spend as plan spend.
        let overageUsed = try usable(
            firstNumber(credit.currentOveragesWithPrecision, credit.currentOverages) ?? 0
        )
        guard totalUsed >= overageUsed else {
            throw UsageProviderError.badResponse(status: 0)
        }
        let planUsed = totalUsed - overageUsed
        let hasUnseparatedBonus = !(credit.bonuses ?? []).isEmpty
        // Bonus spend is folded into currentUsage, so planUsed can exceed the plan ceiling.
        if !hasUnseparatedBonus {
            guard planUsed <= planLimit else {
                throw UsageProviderError.badResponse(status: 0)
            }
        }

        let availability = overageAvailability(response.overageConfiguration?.overageStatus)
        let overageCap: Double?
        if availability == true,
           let cap = firstNumber(credit.overageCapWithPrecision, credit.overageCap) {
            overageCap = try usable(cap)
        } else {
            overageCap = nil
        }
        // ENABLED without a cap is incomplete, not disabled.
        let overageEnabled: Bool? = (availability == true && overageCap == nil)
            ? nil
            : availability

        return CreditLimits(
            planUsed: planUsed,
            planLimit: planLimit,
            overageUsed: overageUsed,
            overageCap: overageCap,
            overageEnabled: overageEnabled,
            overageCharges: credit.overageCharges.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            resetAt: resetDate(credit.nextDateReset ?? response.nextDateReset),
            hasUnseparatedBonus: hasUnseparatedBonus
        )
    }

    // MARK: - SQLite

    // MARK: - Parse helpers

    private static func overageAvailability(_ status: String?) -> Bool? {
        guard let status, !status.isEmpty else { return nil }
        switch status.uppercased() {
        case "ENABLED": return true
        case "DISABLED": return false
        default: return nil
        }
    }

    private static func firstNumber(_ values: Double?...) -> Double? {
        for value in values {
            if let value { return value }
        }
        return nil
    }

    private static func usable(_ value: Double) throws -> Double {
        guard value.isFinite, value >= 0 else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return value
    }

    /// Plausible Unix seconds: 2001-09-09 through 2100-01-01. A value outside
    /// this range is a unit change, not a date — milliseconds would land far
    /// beyond any real reset.
    private static let resetRange: ClosedRange<Double> = 1_000_000_000...4_102_444_800

    private static func resetDate(_ value: Double?) -> Date? {
        guard let value, value.isFinite, resetRange.contains(value) else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    private struct UsageLimitsResponse: Decodable {
        let usageBreakdownList: [UsageBreakdown]
        let overageConfiguration: OverageConfiguration?
        let nextDateReset: Double?
    }

    private struct UsageBreakdown: Decodable {
        let resourceType: String?
        let currentUsageWithPrecision: Double?
        let currentUsage: Double?
        let usageLimitWithPrecision: Double?
        let usageLimit: Double?
        let currentOveragesWithPrecision: Double?
        let currentOverages: Double?
        let overageCapWithPrecision: Double?
        let overageCap: Double?
        let overageCharges: Double?
        let nextDateReset: Double?
        let bonuses: [BonusEntry]?

        struct BonusEntry: Decodable {}
    }

    private struct OverageConfiguration: Decodable {
        let overageStatus: String?
    }
}

enum GitHubCopilotUsage {
    private static let order = ["premium_interactions", "chat", "completions"]

    static func plan(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ((root["copilot_plan"] as? String) ?? (root["plan"] as? String))?.nonEmptyPlan
    }

    static func windows(from data: Data) throws -> [LimitWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quotas = root["quota_snapshots"] as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        let keys = order + quotas.keys.filter { !order.contains($0) }.sorted()
        let windows = keys.compactMap { key -> LimitWindow? in
            guard let quota = quotas[key] as? [String: Any] else { return nil }
            return window(id: key, quota: quota, root: root)
        }
        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered(L10n.t("GitHub Copilot reported no metered quotas"))
        }
        return windows
    }

    private static func window(id: String, quota: [String: Any], root: [String: Any]) -> LimitWindow? {
        if (quota["unlimited"] as? Bool) == true { return nil }

        let entitlement = number(quota["entitlement"])
        let remaining = number(quota["remaining"])
        let used = number(quota["used"])
        let reset = date(quota["reset_date"] ?? quota["reset_at"] ?? quota["resets_at"])
            ?? date(root["quota_reset_date"])

        if entitlement == 0 { return nil }
        if let entitlement, entitlement > 0 {
            guard let consumed = used ?? remaining.map({ max(0, entitlement - $0) }) else { return nil }
            return LimitWindow(id: id, label: label(for: id),
                               usedFraction: max(0, consumed / entitlement), resetsAt: reset,
                               duration: monthlyDuration(endingAt: reset))
        }
        if let remaining, remaining >= 0, used == nil {
            return remaining == 0 && entitlement == 0 ? nil
                : LimitWindow(id: id, label: label(for: id),
                              remaining: Int(remaining.rounded()), resetsAt: reset)
        }
        if let used, used >= 0 {
            return LimitWindow(id: id, label: label(for: id),
                               used: Int(used.rounded()), resetsAt: reset)
        }
        return nil
    }

    /// Copilot allowances reset at midnight UTC on the first of each month.
    private static func monthlyDuration(endingAt reset: Date?) -> TimeInterval? {
        guard let reset else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.day, .hour, .minute, .second], from: reset)
        guard parts.day == 1, parts.hour == 0, parts.minute == 0, parts.second == 0,
              let previousMonth = calendar.date(byAdding: .second, value: -1, to: reset)
        else { return nil }
        return calendar.dateInterval(of: .month, for: previousMonth)?.duration
    }

    private static func number(_ value: Any?) -> Double? {
        AIUsageParser.number(value)
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    private static func label(for id: String) -> String {
        switch id {
        case "premium_interactions": return "Premium requests"
        case "chat":                return "Chat requests"
        case "completions":         return "Completions"
        default:
            return id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}


