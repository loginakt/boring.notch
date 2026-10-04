import Foundation

@main
struct AIQuotaRefreshPolicyTest {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_000)
        var policy = AIQuotaRefreshPolicy()

        // Rate limit backoff
        assert(policy.canRequest(.claude, now: now), "Should be requestable initially")

        policy.recordRateLimit(.claude, retryAfter: 300, now: now)
        assert(!policy.canRequest(.claude, now: now.addingTimeInterval(299)), "Should wait until retry-after expires")
        assert(policy.canRequest(.claude, now: now.addingTimeInterval(300)), "Should be requestable when retry-after expires")

        policy.recordRateLimit(.claude, retryAfter: nil, now: now)
        assert(!policy.canRequest(.claude, now: now.addingTimeInterval(1_799)), "Should use default 30m backoff when retry-after is nil")
        assert(policy.canRequest(.claude, now: now.addingTimeInterval(1_800)), "Default backoff should expire after 30 minutes")

        // Auth failure backoff
        policy.recordAuthFailure(.claude, now: now)
        assert(!policy.canRequest(.claude, now: now.addingTimeInterval(899)), "Auth failure should block for 15 minutes")
        assert(policy.canRequest(.claude, now: now.addingTimeInterval(900)), "Auth failure backoff should expire after 15 minutes")

        // Manual refresh lifts an auth backoff but not a rate limit
        policy.recordAuthFailure(.claude, now: now)
        policy.clearAuthFailure(.claude)
        assert(policy.canRequest(.claude, now: now), "Clearing an auth failure should allow a retry")
        policy.recordRateLimit(.claude, retryAfter: 300, now: now)
        policy.clearAuthFailure(.claude)
        assert(!policy.canRequest(.claude, now: now), "Clearing an auth failure must not lift a rate limit")

        // Block message
        policy.recordAuthFailure(.claude, now: now)
        let msg = policy.blockMessage(for: .claude, now: now)
        assert(msg != nil && msg!.contains("Token expired"), "Auth failure message should mention token expiry")

        policy.recordRateLimit(.claude, retryAfter: 60, now: now)
        let rlMsg = policy.blockMessage(for: .claude, now: now)
        assert(rlMsg != nil && rlMsg!.contains("Rate limited"), "Rate limit message should mention rate limiting")

        // Success clears backoff
        policy.recordRateLimit(.claude, retryAfter: 300, now: now)
        policy.recordSuccess(.claude)
        assert(policy.canRequest(.claude, now: now), "Success should clear backoff")
        assert(policy.blockMessage(for: .claude, now: now) == nil, "No block message after success")

        print("All tests passed.")
    }
}
