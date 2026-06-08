import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/providers/ai_runtime_provider.dart';
import 'package:recall_app/services/ai/ai_entitlement.dart';
import 'package:recall_app/services/ai/ai_quota_policy.dart';
import 'package:recall_app/services/ai_analytics_service.dart';
import 'package:recall_app/services/ai_task.dart';

const Map<AiTaskType, String> _meteredTaskLabels = {
  AiTaskType.conversationTurn: 'AI 對話',
  AiTaskType.smartDistractors: '測驗智慧選項',
  AiTaskType.photoImport: '拍照建卡',
  AiTaskType.speakingScore: '口說評分',
};

const Map<AiEntitlement, String> _planLabels = {
  AiEntitlement.free: '免費',
  AiEntitlement.plus: 'Plus',
  AiEntitlement.proAi: 'Pro AI',
  AiEntitlement.classroom: '班級',
};

/// One metered task's daily usage row.
class AiUsageRow {
  final AiTaskType task;
  final String label;
  final int used;
  final int limit; // AiQuotaPolicy.unlimited = no cap

  const AiUsageRow({
    required this.task,
    required this.label,
    required this.used,
    required this.limit,
  });
}

/// Everything [AiUsageCard] needs to render — assembled once by
/// [aiUsageViewProvider] (not on every widget build) and overridable in tests
/// so the card never has to touch Hive directly.
class AiUsageView {
  final AiEntitlement entitlement;
  final List<AiUsageRow> rows;
  final AiUsageSummary summary;

  const AiUsageView({
    required this.entitlement,
    required this.rows,
    required this.summary,
  });
}

/// Builds the usage view once per open (autoDispose-cached), recomputing only
/// when the effective entitlement changes — so the 24h summary's Hive scan does
/// NOT run on every settings rebuild/scroll.
final aiUsageViewProvider = Provider.autoDispose<AiUsageView>((ref) {
  final entitlement = ref.watch(effectiveAiEntitlementProvider);
  final quota = ref.watch(aiQuotaServiceProvider);
  final summary = AiAnalyticsService().getUsageSummary();
  final rows = [
    for (final entry in _meteredTaskLabels.entries)
      AiUsageRow(
        task: entry.key,
        label: entry.value,
        used: quota.usageToday(entry.key),
        limit: AiQuotaPolicy.dailyLimit(entitlement, entry.key),
      ),
  ];
  return AiUsageView(entitlement: entitlement, rows: rows, summary: summary);
});

/// Settings card that makes the AI cost gate (§2.6) visible: the current plan,
/// today's per-task cloud quota usage, and a rough 24h token-usage summary.
///
/// The plan *selector* is debug-only — in release the entitlement is fixed to
/// the (currently free) effective tier and is shown read-only. Real plan
/// changes must come from server-verified entitlement, never from this UI
/// (see [effectiveAiEntitlementProvider]).
class AiUsageCard extends ConsumerWidget {
  const AiUsageCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final view = ref.watch(aiUsageViewProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.insights_outlined,
                size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('AI 用量與方案', style: theme.textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '雲端 AI 每天有免費額度，本機 AI 永遠免費、不計入。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),

        // —— Plan ——
        Text('方案', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        if (kDebugMode)
          _DebugPlanSelector(current: view.entitlement)
        else
          Chip(label: Text(_planLabels[view.entitlement] ?? view.entitlement.name)),
        const SizedBox(height: 16),

        // —— Per-task daily usage ——
        Text('今日雲端用量', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        for (final row in view.rows)
          _UsageRow(label: row.label, used: row.used, limit: row.limit),
        const SizedBox(height: 12),

        // —— 24h token summary ——
        Text(
          view.summary.calls == 0
              ? '近 24 小時：尚無雲端 AI 呼叫'
              : '近 24 小時：${view.summary.calls} 次呼叫'
                  '（成功 ${view.summary.successes}）'
                  '，約 ${view.summary.totalTokens} tokens',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Debug-only plan switcher. Writes the *local* entitlement notifier, which only
/// affects [effectiveAiEntitlementProvider] in debug builds — it can never grant
/// a paid tier in release.
class _DebugPlanSelector extends ConsumerWidget {
  const _DebugPlanSelector({required this.current});

  final AiEntitlement current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final e in AiEntitlement.values)
          ChoiceChip(
            label: Text(_planLabels[e] ?? e.name),
            selected: e == current,
            onSelected: (sel) {
              if (sel) {
                ref.read(aiEntitlementProvider.notifier).setEntitlement(e);
              }
            },
          ),
        Text(
          '(dev)',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({
    required this.label,
    required this.used,
    required this.limit,
  });

  final String label;
  final int used;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unlimited = limit == AiQuotaPolicy.unlimited;
    final exhausted = !unlimited && used >= limit;
    final fraction = unlimited
        ? 0.0
        : (limit == 0 ? 1.0 : (used / limit).clamp(0.0, 1.0));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: theme.textTheme.bodyMedium),
              Text(
                unlimited ? '無限' : '$used / $limit',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: exhausted
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: exhausted ? FontWeight.bold : null,
                ),
              ),
            ],
          ),
          if (!unlimited) ...[
            const SizedBox(height: 4),
            // Ticker-free progress bar (a plain LinearProgressIndicator keeps a
            // Ticker alive, which is unnecessary here).
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 4,
                child: Stack(
                  children: [
                    ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const SizedBox(width: double.infinity, height: 4),
                    ),
                    FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: fraction,
                      child: ColoredBox(
                        color: exhausted
                            ? theme.colorScheme.error
                            : theme.colorScheme.primary,
                        child: const SizedBox(height: 4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
