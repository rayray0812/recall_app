import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/providers/ai_runtime_provider.dart';
import 'package:recall_app/providers/auth_provider.dart';
import 'package:recall_app/services/ai/ai_proxy_client.dart';
import 'package:recall_app/services/ai/ai_quota_policy.dart';
import 'package:recall_app/services/ai/ai_router.dart';
import 'package:recall_app/services/ai/card_lookup_service.dart';
import 'package:recall_app/services/ai_task.dart';

/// Whether AI card auto-fill can run at all right now (any route). The card
/// editor uses this to decide whether to show the "✨ 智慧填入" affordance.
final cardLookupAvailableProvider = Provider.autoDispose<bool>((ref) {
  final route = ref.watch(aiRouteProvider(AiTaskType.cardLookup)).valueOrNull;
  if (route == null) return false;
  switch (route.target) {
    case AiRouteTarget.unavailable:
      return false;
    case AiRouteTarget.local:
      return true;
    case AiRouteTarget.cloud:
      // Cloud path only works for a signed-in user (proxy) — signed-out users
      // fall back to the manual, no-AI flow.
      return ref.watch(currentUserProvider) != null;
  }
});

/// Auto-fill a vocabulary card from an English [term]: returns a
/// {definition, pos, example} or null when no usable result is available.
///
/// Local-first ([AiTaskTier.localPreferred]): if the on-device model is routed
/// and produces a usable result it is used for free. When the local model is
/// missing, offline-routed, or its output fails the quality gate, this escalates
/// to the Grasp server proxy for signed-in users (metered server-side — free
/// users' cloud calls consume their daily cardLookup allowance). Signed-out
/// users get nothing here and use the manual flow.
final cardLookupProvider = FutureProvider.autoDispose
    .family<CardLookupResult?, String>((ref, term) async {
  final t = term.trim();
  if (t.isEmpty) return null;

  const task = AiTaskType.cardLookup;
  final route = await ref.watch(aiRouteProvider(task).future);

  // 1) Local-first: try the on-device model when routed there.
  if (route.isLocal) {
    final engine = await ref.watch(localLlmEngineProvider.future);
    final local = await CardLookupService.generateLocal(engine: engine, term: t);
    if (local != null) return local; // good local result → free, private, done.
    // Otherwise fall through and escalate to the cloud proxy.
  } else if (route.target == AiRouteTarget.unavailable) {
    return null;
  }

  // 2) Cloud escalation (proxy). Respect privacy mode + connectivity, and only
  // proceed for signed-in users on a proxy-backed task.
  if (ref.read(aiPrivacyModeProvider)) return null;
  if (!(ref.read(aiOnlineProvider).valueOrNull ?? true)) return null;
  if (!ref.read(cloudConfiguredForTaskProvider(task))) return null;
  if (ref.read(currentUserProvider) == null) return null;

  // Best-effort local gate for UI consistency; the server is authoritative and
  // does the real consume (consume_ai_daily_quota), so we do NOT consume here.
  final entitlement = ref.read(effectiveAiEntitlementProvider);
  final usedToday = ref.read(aiQuotaServiceProvider).usageToday(task);
  if (!AiQuotaPolicy.allows(
    entitlement: entitlement,
    type: task,
    usedToday: usedToday,
  )) {
    return null;
  }

  return _proxyLookup(ref, t);
});

Future<CardLookupResult?> _proxyLookup(Ref ref, String term) async {
  try {
    final response = await ref.read(aiProxyClientProvider).complete(
          taskType: AiTaskType.cardLookup,
          messages: [
            const AiProxyMessage(
              role: AiProxyRole.system,
              content: CardLookupService.systemPrompt,
            ),
            AiProxyMessage(
              role: AiProxyRole.user,
              content: CardLookupService.buildPrompt(term),
            ),
          ],
          temperature: 0.3,
          maxTokens: CardLookupService.maxTokens,
        );
    final result = CardLookupService.parse(response.text, term: term);
    return (result != null && result.isUsable) ? result : null;
  } catch (_) {
    return null;
  }
}
