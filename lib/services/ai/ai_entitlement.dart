/// The user's AI entitlement tier, which gates daily cloud-AI quota.
///
/// Core memory features (FSRS, local-only AI) are always free; only metered
/// cloud-AI tasks are bounded by [AiQuotaPolicy] per tier. See
/// docs/ai_roadmap_status.md §2.6 — the promise is "core features free; high-cost
/// AI has a free daily allowance, heavy use needs Plus/Pro AI".
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
