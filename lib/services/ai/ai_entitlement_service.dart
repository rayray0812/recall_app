import 'package:recall_app/services/ai/ai_entitlement.dart';
import 'package:recall_app/services/supabase_service.dart';

/// Reads the server-verified AI entitlement for the current user.
///
/// This is the client-side cache/read path only. Granting, extending, or
/// revoking paid tiers must be done server-side by StoreKit/RevenueCat/admin
/// flows that write `user_ai_entitlements`.
class AiEntitlementService {
  AiEntitlementService(this._supabaseService);

  final SupabaseService _supabaseService;

  Future<AiEntitlement> fetchCurrent() async {
    final client = _supabaseService.clientOrNull;
    final user = _supabaseService.currentUser;
    if (client == null || user == null) return AiEntitlement.free;

    final row = await client
        .from('user_ai_entitlements')
        .select('tier, expires_at')
        .eq('user_id', user.id)
        .maybeSingle();

    if (row == null) return AiEntitlement.free;

    final expiresAtRaw = row['expires_at']?.toString();
    final expiresAt = expiresAtRaw == null
        ? null
        : DateTime.tryParse(expiresAtRaw)?.toUtc();
    if (isExpired(expiresAt)) return AiEntitlement.free;

    return parseTier(row['tier']?.toString());
  }

  static AiEntitlement parseTier(String? tier) {
    return switch (tier?.trim()) {
      'plus' => AiEntitlement.plus,
      'pro_ai' => AiEntitlement.proAi,
      'classroom' => AiEntitlement.classroom,
      _ => AiEntitlement.free,
    };
  }

  static bool isExpired(DateTime? expiresAt, {DateTime? now}) {
    if (expiresAt == null) return false;
    return !expiresAt.isAfter((now ?? DateTime.now()).toUtc());
  }
}
