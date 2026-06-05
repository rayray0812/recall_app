/// The user's AI entitlement tier, which gates daily cloud-AI quota.
///
/// Core memory features (FSRS, local-only AI) are always free; only metered
/// cloud-AI tasks are bounded by [AiQuotaPolicy] per tier. See
/// docs/ai_roadmap_status.md §2.6 — the promise is "core features free; high-cost
/// AI has a free daily allowance, heavy use needs Plus/Pro AI".
///
/// ⚠️ **LOCAL PLACEHOLDER ONLY — not a security/billing boundary.** The current
/// tier is read from local storage (`aiEntitlementProvider`), so it can be
/// edited by a determined user. That is acceptable while the user supplies their
/// own API key (the cost is theirs). Before Grasp uses its own server-side
/// provider keys, the authoritative entitlement MUST come from server
/// verification (RevenueCat / StoreKit / Supabase) — local should only cache it.
enum AiEntitlement {
  /// Default tier: bounded daily allowance for cloud AI.
  free,

  /// Paid consumer tier: much higher daily caps.
  plus,

  /// Paid AI-focused tier: unlimited cloud AI.
  proAi,

  /// School/seat-licensed tier: unlimited cloud AI.
  classroom,
}
