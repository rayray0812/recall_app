import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/providers/ai_runtime_provider.dart';
import 'package:recall_app/services/ai_task.dart';
import 'package:recall_app/services/local_ai_service.dart';

/// Whether the L1 review-hint affordance can run right now.
///
/// True only when [AiRouter] routes the review-hint task to a local engine
/// (model installed / Apple FM available and privacy/availability allow it).
/// AsyncValue because device capability + model readiness resolve
/// asynchronously; UI hides the affordance until it resolves to true.
final localHintAvailableProvider = Provider.autoDispose<AsyncValue<bool>>((ref) {
  return ref
      .watch(aiRouteProvider(AiTaskType.reviewHint))
      .whenData((decision) => decision.isLocal);
});

/// Whether the L2 mnemonic affordance can run right now.
///
/// Mirrors [localHintAvailableProvider] but for the mnemonic task: true only
/// when [AiRouter] routes it to a local engine. UI hides the button until this
/// resolves to true.
final localMnemonicAvailableProvider =
    Provider.autoDispose<AsyncValue<bool>>((ref) {
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
final reviewHintProvider =
    FutureProvider.autoDispose.family<String?, ReviewHintRequest>((ref, req) async {
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
final mnemonicProvider =
    FutureProvider.autoDispose.family<String?, ReviewHintRequest>((ref, req) async {
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
          chosenTerm == other.chosenTerm;

  @override
  int get hashCode => Object.hash(targetTerm, chosenTerm);
}

/// L3: lazy provider that explains a quiz confusion.
final confusionExplanationProvider =
    FutureProvider.autoDispose.family<String?, ConfusionRequest>((ref, req) async {
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
