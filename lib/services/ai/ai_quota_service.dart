import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:recall_app/core/constants/app_constants.dart';
import 'package:recall_app/services/ai/ai_entitlement.dart';
import 'package:recall_app/services/ai/ai_quota_policy.dart';
import 'package:recall_app/services/ai_task.dart';

/// Tracks per-day cloud-AI usage counts in Hive and enforces [AiQuotaPolicy].
///
/// Counts are bucketed under a single UTC date key, so the whole bucket is
/// discarded (and usage effectively resets to zero) the first time it is read on
/// a new day — no scheduled job needed. Only metered tasks are counted; calling
/// [consume] for an unmetered (local) task is a no-op.
class AiQuotaService {
  Box get _box => Hive.box(AppConstants.hiveSettingsBox);

  /// UTC date bucket key, e.g. "2026-06-05".
  static String dayKey([DateTime? now]) {
    final d = (now ?? DateTime.now()).toUtc();
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  /// Today's counts map ({taskName: count}); empty when the stored bucket is
  /// from a previous day or missing.
  Map<String, int> _countsForToday() {
    try {
      final raw = _box.get(AppConstants.settingAiQuotaKey);
      if (raw is Map && raw['day'] == dayKey()) {
        final counts = raw['counts'];
        if (counts is Map) {
          return counts.map(
            (k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0),
          );
        }
      }
    } catch (e) {
      debugPrint('AiQuotaService read failed: $e');
    }
    return <String, int>{};
  }

  /// How many cloud calls of [type] were made today.
  int usageToday(AiTaskType type) => _countsForToday()[type.name] ?? 0;

  /// Whether a cloud call of [type] is allowed right now for [entitlement].
  bool canRun(AiEntitlement entitlement, AiTaskType type) => AiQuotaPolicy.allows(
        entitlement: entitlement,
        type: type,
        usedToday: usageToday(type),
      );

  /// Remaining cloud calls of [type] today ([AiQuotaPolicy.unlimited] = no cap).
  int remaining(AiEntitlement entitlement, AiTaskType type) =>
      AiQuotaPolicy.remaining(
        entitlement: entitlement,
        type: type,
        usedToday: usageToday(type),
      );

  /// Record one cloud call of [type]. No-op for unmetered (local) tasks.
  Future<void> consume(AiTaskType type) async {
    if (!AiQuotaPolicy.isMetered(type)) return;
    try {
      final counts = _countsForToday();
      counts[type.name] = (counts[type.name] ?? 0) + 1;
      await _box.put(AppConstants.settingAiQuotaKey, {
        'day': dayKey(),
        'counts': counts,
      });
    } catch (e) {
      debugPrint('AiQuotaService consume failed: $e');
    }
  }
}
