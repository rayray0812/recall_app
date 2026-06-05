import 'package:recall_app/services/ai/ai_entitlement.dart';
import 'package:recall_app/services/ai_task.dart';

/// Pure, table-driven policy for daily cloud-AI quotas (docs §2.6).
///
/// No IO — every method is a pure function of its inputs, so the whole cost
/// model is unit-testable without Hive, network, or a device. On-device
/// execution is always free; only *cloud* calls are metered, so [isMetered]
/// marks the cost-bearing task types and the daily caps apply only to them.
///
/// The numbers here are intentionally tunable placeholders: the point is the
/// mechanism (per-tier, per-task daily caps with graceful exhaustion), not the
/// exact limits, which product/pricing will set later.
abstract final class AiQuotaPolicy {
  /// Sentinel daily limit meaning "no cap".
  static const int unlimited = -1;

  /// Whether running [type] in the cloud incurs cost and is therefore metered.
  /// Local-only tasks (hints / mnemonic / confusion / example sentence) run on
  /// the device for free and never consume quota.
  static bool isMetered(AiTaskType type) {
    return switch (type) {
      AiTaskType.conversationTurn ||
      AiTaskType.smartDistractors ||
      AiTaskType.photoImport ||
      AiTaskType.speakingScore => true,
      AiTaskType.reviewHint ||
      AiTaskType.mnemonic ||
      AiTaskType.confusionDiagnosis ||
      AiTaskType.exampleSentence => false,
    };
  }

  /// Daily cap for [type] under [entitlement]; [unlimited] means no cap.
  static int dailyLimit(AiEntitlement entitlement, AiTaskType type) {
    if (!isMetered(type)) return unlimited;
    return switch (entitlement) {
      AiEntitlement.proAi || AiEntitlement.classroom => unlimited,
      AiEntitlement.plus => switch (type) {
        AiTaskType.conversationTurn => 200,
        AiTaskType.smartDistractors => 500,
        AiTaskType.photoImport => 100,
        AiTaskType.speakingScore => 200,
        _ => unlimited,
      },
      AiEntitlement.free => switch (type) {
        AiTaskType.conversationTurn => 30,
        AiTaskType.smartDistractors => 60,
        AiTaskType.photoImport => 10,
        AiTaskType.speakingScore => 20,
        _ => unlimited,
      },
    };
  }

  /// Whether another cloud call is allowed given [usedToday].
  static bool allows({
    required AiEntitlement entitlement,
    required AiTaskType type,
    required int usedToday,
  }) {
    final limit = dailyLimit(entitlement, type);
    if (limit == unlimited) return true;
    return usedToday < limit;
  }

  /// Remaining cloud calls today; [unlimited] stays [unlimited], and an
  /// over-count clamps to 0 (never negative).
  static int remaining({
    required AiEntitlement entitlement,
    required AiTaskType type,
    required int usedToday,
  }) {
    final limit = dailyLimit(entitlement, type);
    if (limit == unlimited) return unlimited;
    final left = limit - usedToday;
    return left < 0 ? 0 : left;
  }
}
