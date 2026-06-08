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
/// own API key (the cost is theirs). Owner-funded AI must use the server-side
/// proxy/entitlement tables (see `docs/ai_cloud_proxy_security_plan.md`), and
/// Flutter should treat local entitlement as a debug/cache value only.
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
