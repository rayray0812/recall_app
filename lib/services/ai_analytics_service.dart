import 'package:hive/hive.dart';
import 'package:recall_app/core/constants/app_constants.dart';
import 'package:recall_app/services/ai_error.dart';
import 'package:recall_app/services/ai_task.dart';

/// Per-provider usage rollup within an [AiUsageSummary].
class AiProviderUsage {
  final int calls;
  final int inputTokens;
  final int outputTokens;

  const AiProviderUsage({
    this.calls = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
  });

  int get totalTokens => inputTokens + outputTokens;
}

/// Aggregated AI usage over a time window, for cost telemetry / a usage UI.
class AiUsageSummary {
  final int calls;
  final int successes;
  final int inputTokens;
  final int outputTokens;
  final Map<String, AiProviderUsage> perProvider;

  const AiUsageSummary({
    this.calls = 0,
    this.successes = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.perProvider = const {},
  });

  int get totalTokens => inputTokens + outputTokens;
  int get failures => calls - successes;
}

/// Lightweight, append-only log of AI operation outcomes stored in Hive.
///
/// Used for debugging rate limits, tracking provider reliability, and
/// providing telemetry data for future cost-optimisation decisions.
/// Maximum [_maxRecords] events are kept; older entries are trimmed.
class AiAnalyticsService {
  static const int _maxRecords = 100;

  Box get _box => Hive.box(AppConstants.hiveSettingsBox);

  /// Log the outcome of an AI task.
  ///
  /// [inputTokens] / [outputTokens] are rough estimates (see [AiTokenEstimator])
  /// used for cost telemetry; pass 0 (the default) for tasks where tokens don't
  /// apply or aren't known. They are only stored when non-zero.
  Future<void> logEvent({
    required AiTaskType taskType,
    required String provider,
    required bool success,
    required Duration elapsed,
    ScanFailureReason? failureReason,
    int inputTokens = 0,
    int outputTokens = 0,
  }) async {
    final raw =
        (_box.get(AppConstants.settingAiEventsKey, defaultValue: <dynamic>[])
                as List)
            .cast<dynamic>();
    final events = List<Map<String, dynamic>>.from(
      raw.map((e) => Map<String, dynamic>.from(e as Map)),
    );

    events.add({
      'at': DateTime.now().toUtc().toIso8601String(),
      'task': taskType.name,
      'provider': provider,
      'result': success ? 'success' : 'failed',
      'elapsed_ms': elapsed.inMilliseconds,
      if (failureReason != null) 'failure_reason': failureReason.name,
      if (inputTokens > 0) 'in_tokens': inputTokens,
      if (outputTokens > 0) 'out_tokens': outputTokens,
    });

    if (events.length > _maxRecords) {
      events.removeRange(0, events.length - _maxRecords);
    }

    await _box.put(AppConstants.settingAiEventsKey, events);
  }

  /// Return recent AI events (newest first), capped at [limit].
  List<Map<String, dynamic>> getRecentEvents({int limit = 20}) {
    final raw =
        (_box.get(AppConstants.settingAiEventsKey, defaultValue: <dynamic>[])
                as List)
            .cast<dynamic>();
    final events = raw
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList()
        .reversed
        .take(limit)
        .toList();
    return events;
  }

  /// Aggregate recent usage for cost telemetry: total calls, successes, and
  /// estimated input/output tokens, broken down per provider. Considers events
  /// from the last [hours] hours (default: 24).
  AiUsageSummary getUsageSummary({int hours = 24}) {
    final cutoff = DateTime.now().toUtc().subtract(Duration(hours: hours));
    final raw =
        (_box.get(AppConstants.settingAiEventsKey, defaultValue: <dynamic>[])
                as List)
            .cast<dynamic>();
    final perProvider = <String, AiProviderUsage>{};
    var calls = 0;
    var successes = 0;
    var inTokens = 0;
    var outTokens = 0;

    for (final e in raw.map((e) => Map<String, dynamic>.from(e as Map))) {
      final at = DateTime.tryParse(e['at'] as String? ?? '');
      if (at == null || !at.isAfter(cutoff)) continue;
      final provider = e['provider']?.toString() ?? 'unknown';
      final ok = e['result'] == 'success';
      final ti = (e['in_tokens'] as num?)?.toInt() ?? 0;
      final to = (e['out_tokens'] as num?)?.toInt() ?? 0;

      calls++;
      if (ok) successes++;
      inTokens += ti;
      outTokens += to;

      final p = perProvider[provider] ?? const AiProviderUsage();
      perProvider[provider] = AiProviderUsage(
        calls: p.calls + 1,
        inputTokens: p.inputTokens + ti,
        outputTokens: p.outputTokens + to,
      );
    }

    return AiUsageSummary(
      calls: calls,
      successes: successes,
      inputTokens: inTokens,
      outputTokens: outTokens,
      perProvider: perProvider,
    );
  }

  /// Return the count of failures for [provider] in the last [hours] hours.
  int recentFailureCount(String provider, {int hours = 1}) {
    final cutoff = DateTime.now().toUtc().subtract(Duration(hours: hours));
    final raw =
        (_box.get(AppConstants.settingAiEventsKey, defaultValue: <dynamic>[])
                as List)
            .cast<dynamic>();
    return raw
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) {
          final at = DateTime.tryParse(e['at'] as String? ?? '');
          return at != null &&
              at.isAfter(cutoff) &&
              e['provider'] == provider &&
              e['result'] == 'failed';
        })
        .length;
  }
}
