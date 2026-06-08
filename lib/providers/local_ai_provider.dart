import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/providers/ai_provider_provider.dart';
import 'package:recall_app/providers/ai_runtime_provider.dart';
import 'package:recall_app/providers/auth_provider.dart';
import 'package:recall_app/services/ai/ai_gateway.dart';
import 'package:recall_app/services/ai/ai_proxy_client.dart';
import 'package:recall_app/services/ai/ai_router.dart';
import 'package:recall_app/services/ai_task.dart';
import 'package:recall_app/services/groq_completion_service.dart';
import 'package:recall_app/services/local_ai_service.dart';

/// Whether the L1 review-hint affordance can run right now.
///
/// True only when [AiRouter] routes the review-hint task to a local engine
/// (model installed / Apple FM available and privacy/availability allow it).
/// AsyncValue because device capability + model readiness resolve
/// asynchronously; UI hides the affordance until it resolves to true.
final localHintAvailableProvider = Provider.autoDispose<AsyncValue<bool>>((
  ref,
) {
  return ref
      .watch(aiRouteProvider(AiTaskType.reviewHint))
      .whenData((decision) => decision.isLocal);
});

/// Whether the L2 mnemonic affordance can run right now.
///
/// Mirrors [localHintAvailableProvider] but for the mnemonic task: true only
/// when [AiRouter] routes it to a local engine. UI hides the button until this
/// resolves to true.
final localMnemonicAvailableProvider = Provider.autoDispose<AsyncValue<bool>>((
  ref,
) {
  return ref
      .watch(aiRouteProvider(AiTaskType.mnemonic))
      .whenData((decision) => decision.isLocal);
});

/// Argument for [reviewHintProvider].
class ReviewHintRequest {
  final String cardId;
  final String term;
  final String definition;

  const ReviewHintRequest({
    required this.cardId,
    required this.term,
    required this.definition,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReviewHintRequest &&
          cardId == other.cardId &&
          term == other.term &&
          definition == other.definition;

  @override
  int get hashCode => Object.hash(cardId, term, definition);
}

/// L1: lazy provider that produces a one-sentence hint for a card.
///
/// AutoDispose so hints don't pile up across review sessions.
/// Family-keyed by [ReviewHintRequest] so different cards have independent
/// caches within the same session.
final reviewHintProvider = FutureProvider.autoDispose
    .family<String?, ReviewHintRequest>((ref, req) async {
      final decision = await ref.watch(
        aiRouteProvider(AiTaskType.reviewHint).future,
      );
      if (!decision.isLocal) return null;
      final engine = await ref.watch(localLlmEngineProvider.future);
      return LocalAiService.generateReviewHint(
        engine: engine,
        term: req.term,
        definition: req.definition,
      );
    });

/// L2: lazy provider that produces a memory mnemonic.
final mnemonicProvider = FutureProvider.autoDispose
    .family<String?, ReviewHintRequest>((ref, req) async {
      final decision = await ref.watch(
        aiRouteProvider(AiTaskType.mnemonic).future,
      );
      if (!decision.isLocal) return null;
      final engine = await ref.watch(localLlmEngineProvider.future);
      return LocalAiService.generateMnemonic(
        engine: engine,
        term: req.term,
        definition: req.definition,
      );
    });

/// Whether the L3 confusion-diagnosis affordance can run right now.
///
/// Mirrors [localHintAvailableProvider] but for the confusion-diagnosis task:
/// true only when [AiRouter] routes it to a local engine. UI hides the
/// "why the mix-up?" affordance until this resolves to true.
final localConfusionAvailableProvider = Provider.autoDispose<AsyncValue<bool>>((
  ref,
) {
  return ref
      .watch(aiRouteProvider(AiTaskType.confusionDiagnosis))
      .whenData((decision) => decision.isLocal);
});

/// Argument for [confusionExplanationProvider].
class ConfusionRequest {
  final String targetTerm;
  final String targetDefinition;
  final String chosenTerm;
  final String chosenDefinition;

  const ConfusionRequest({
    required this.targetTerm,
    required this.targetDefinition,
    required this.chosenTerm,
    required this.chosenDefinition,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConfusionRequest &&
          targetTerm == other.targetTerm &&
          targetDefinition == other.targetDefinition &&
          chosenTerm == other.chosenTerm &&
          chosenDefinition == other.chosenDefinition;

  @override
  int get hashCode =>
      Object.hash(targetTerm, targetDefinition, chosenTerm, chosenDefinition);
}

/// L3: lazy provider that explains a quiz confusion.
final confusionExplanationProvider = FutureProvider.autoDispose
    .family<String?, ConfusionRequest>((ref, req) async {
      final decision = await ref.watch(
        aiRouteProvider(AiTaskType.confusionDiagnosis).future,
      );
      if (!decision.isLocal) return null;
      final engine = await ref.watch(localLlmEngineProvider.future);
      return LocalAiService.generateConfusionExplanation(
        engine: engine,
        targetTerm: req.targetTerm,
        targetDefinition: req.targetDefinition,
        chosenTerm: req.chosenTerm,
        chosenDefinition: req.chosenDefinition,
      );
    });

/// Whether the smart-distractor enhancement can run right now.
///
/// Unlike the localOnly affordances above, smartDistractors is cloudPreferred
/// (see §2.5): it runs in the cloud by default and only falls back to the local
/// engine when offline. So "available" means routed *anywhere* (local or
/// cloud), not just on-device. For the cloud path, logged-in users can use the
/// Grasp server-side proxy; signed-out users still need their own Groq key.
/// The quiz uses this to decide whether to attempt AI distractor enrichment,
/// falling back to random other-card options when unavailable.
final smartDistractorsAvailableProvider =
    Provider.autoDispose<AsyncValue<bool>>((ref) {
      return ref.watch(aiRouteProvider(AiTaskType.smartDistractors)).whenData((
        decision,
      ) {
        switch (decision.target) {
          case AiRouteTarget.unavailable:
            return false;
          case AiRouteTarget.cloud:
            return ref.watch(currentUserProvider) != null ||
                ref.watch(groqKeyProvider).trim().isNotEmpty;
          case AiRouteTarget.local:
            return true;
        }
      });
    });

/// Argument for [smartDistractorsProvider].
class SmartDistractorRequest {
  final String cardId;
  final String term;
  final String definition;
  final String correctOption;
  final bool reversed;
  final int count;

  const SmartDistractorRequest({
    required this.cardId,
    required this.term,
    required this.definition,
    required this.correctOption,
    required this.reversed,
    this.count = 3,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SmartDistractorRequest &&
          cardId == other.cardId &&
          reversed == other.reversed &&
          count == other.count;

  @override
  int get hashCode => Object.hash(cardId, reversed, count);
}

/// Lazy provider that produces plausible wrong options for a quiz question.
///
/// smartDistractors is cloudPreferred, so logged-in users route to the Grasp
/// server-side proxy by default (owner tokens stay in Supabase secrets) and
/// only use the on-device engine as an offline fallback. Signed-out users with
/// their own Groq key keep the old BYO direct path. Returns null (→ caller keeps
/// its random-card baseline) when the task is unavailable, quota is exhausted,
/// no cloud credential path exists, or the model returns too few usable options.
final smartDistractorsProvider = FutureProvider.autoDispose
    .family<List<String>?, SmartDistractorRequest>((ref, req) async {
      const task = AiTaskType.smartDistractors;
      final route = await ref.watch(aiRouteProvider(task).future);
      final entitlement = ref.watch(effectiveAiEntitlementProvider);
      final quota = ref.watch(aiQuotaServiceProvider);

      final gw = AiGateway.decide(
        route: route,
        entitlement: entitlement,
        type: task,
        usedToday: quota.usageToday(task),
      );

      switch (gw.outcome) {
        case AiGatewayOutcome.runCloud:
          final user = ref.watch(currentUserProvider);
          if (user != null) {
            return _generateProxyDistractors(ref, req);
          }

          final groqKey = ref.watch(groqKeyProvider).trim();
          if (groqKey.isEmpty) return null;
          // Atomically check + consume one metered unit at the dispatch point;
          // if the quota was just exhausted by a concurrent call, skip to the
          // random-card baseline rather than over-spending.
          if (!await quota.tryConsume(entitlement, task)) return null;
          final groq = GroqCompletionService(apiKey: groqKey);
          try {
            return await groq.generateDistractors(
              term: req.term,
              definition: req.definition,
              correctOption: req.correctOption,
              reversed: req.reversed,
              count: req.count,
            );
          } finally {
            // One-shot per question — release the HTTP connection pool.
            groq.close();
          }
        case AiGatewayOutcome.runLocal:
          final engine = await ref.watch(localLlmEngineProvider.future);
          return LocalAiService.generateDistractors(
            engine: engine,
            term: req.term,
            definition: req.definition,
            correctOption: req.correctOption,
            reversed: req.reversed,
            count: req.count,
          );
        case AiGatewayOutcome.blockedQuota:
        case AiGatewayOutcome.unavailable:
          return null;
      }
    });

Future<List<String>?> _generateProxyDistractors(
  Ref ref,
  SmartDistractorRequest req,
) async {
  final prompt = LocalAiService.buildDistractorsPrompt(
    term: req.term,
    definition: req.definition,
    correctOption: req.correctOption,
    reversed: req.reversed,
    count: req.count,
  );
  try {
    final response = await ref
        .read(aiProxyClientProvider)
        .complete(
          taskType: AiTaskType.smartDistractors,
          messages: [
            const AiProxyMessage(
              role: AiProxyRole.system,
              content:
                  'You generate concise multiple-choice distractors for a vocabulary quiz. Return only one option per line.',
            ),
            AiProxyMessage(role: AiProxyRole.user, content: prompt),
          ],
          temperature: 0.8,
          maxTokens: 180,
        );
    final list = LocalAiService.parseDistractorLines(
      response.text,
      exclude: req.correctOption,
      max: req.count,
    );
    return list.length >= req.count ? list : null;
  } catch (_) {
    return null;
  }
}
