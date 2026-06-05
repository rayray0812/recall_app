import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:recall_app/core/constants/app_constants.dart';
import 'package:recall_app/services/ai/ai_entitlement.dart';
import 'package:recall_app/services/ai/ai_quota_policy.dart';
import 'package:recall_app/services/ai_task.dart';

/// Tracks per-day cloud-AI usage counts and enforces [AiQuotaPolicy].
///
/// Counts are bucketed under a single UTC date key, so the whole bucket is
/// discarded (and usage effectively resets to zero) the first time it is read on
/// a new day — no scheduled job needed. Only metered tasks are counted.
///
/// ⚠️ This is a **local product quota**, not a security or billing boundary. It
/// limits how often the app *chooses* to call a cloud provider, which is exactly
/// the right protection while the user supplies their own API key (the cost is
/// theirs). It does **not** stop a determined user from editing local storage.
/// Before Grasp ever uses its own server-side provider keys, real entitlement
/// must come from server verification (see [AiEntitlement]).
///
/// Concurrency: a single instance is shared via `aiQuotaServiceProvider`, and an
/// in-memory map ([_counts]) is the authority for the loaded day. [tryConsume]
/// does its check + increment synchronously (no `await` between them), so two
/// concurrent callers can never both pass the same last remaining slot —
/// independent of Hive's async disk persistence.
class AiQuotaService {
  Box get _box => Hive.box(AppConstants.hiveSettingsBox);

  /// The UTC day [_counts] was loaded for; null until first access.
  String? _loadedDay;

  /// In-memory authoritative usage counts ({taskName: count}) for [_loadedDay].
  Map<String, int> _counts = <String, int>{};

  /// UTC date bucket key, e.g. "2026-06-05".
  static String dayKey([DateTime? now]) {
    final d = (now ?? DateTime.now()).toUtc();
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  /// Ensure [_counts] holds today's counts, reloading from Hive on a day change.
  Map<String, int> _ensureToday() {
    final today = dayKey();
    if (_loadedDay == today) return _counts;
    _loadedDay = today;
    _counts = _readPersisted(today);
    return _counts;
  }

  Map<String, int> _readPersisted(String today) {
    try {
      final raw = _box.get(AppConstants.settingAiQuotaKey);
      if (raw is Map && raw['day'] == today) {
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
  int usageToday(AiTaskType type) => _ensureToday()[type.name] ?? 0;

  /// Whether a cloud call of [type] is allowed right now (read-only; for UI).
  /// Prefer [tryConsume] at the actual dispatch point — it is atomic.
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

  /// Atomically check-and-consume one cloud unit for [type] under [entitlement].
  ///
  /// Returns true when the call is allowed (and a unit was consumed), false when
  /// the daily quota is already exhausted. Unmetered (local) tasks always return
  /// true without consuming. The check and increment happen with no `await`
  /// between them, so concurrent callers cannot both pass the last slot.
  Future<bool> tryConsume(AiEntitlement entitlement, AiTaskType type) async {
    if (!AiQuotaPolicy.isMetered(type)) return true;
    final counts = _ensureToday();
    final used = counts[type.name] ?? 0;
    if (!AiQuotaPolicy.allows(
      entitlement: entitlement,
      type: type,
      usedToday: used,
    )) {
      return false;
    }
    // Synchronous in-memory increment — this is the atomic commit point.
    counts[type.name] = used + 1;
    // Persistence is best-effort; losing a count to an app kill under-counts in
    // the user's favour, which is acceptable.
    await _persist();
    return true;
  }

  Future<void> _persist() async {
    try {
      await _box.put(AppConstants.settingAiQuotaKey, {
        'day': _loadedDay ?? dayKey(),
        'counts': Map<String, int>.from(_counts),
      });
    } catch (e) {
      debugPrint('AiQuotaService persist failed: $e');
    }
  }
}
