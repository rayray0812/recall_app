import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/providers/ai_runtime_provider.dart';
import 'package:recall_app/services/ai/ai_entitlement.dart';
import 'package:recall_app/services/ai/ai_quota_policy.dart';
import 'package:recall_app/services/ai_analytics_service.dart';
import 'package:recall_app/services/ai_task.dart';

/// Settings card that makes the AI cost gate (§2.6) visible: the current plan,
/// today's per-task cloud quota usage, and a rough 24h token-usage summary.
///
/// The plan selector writes to the local [aiEntitlementProvider] — a dev/local
/// placeholder until real server-verified entitlement is wired up (see
/// [AiEntitlement]); it lets the user (and tests) see how quotas change per tier.
class AiUsageCard extends ConsumerWidget {
  const AiUsageCard({super.key});

  static const _meteredTasks = <AiTaskType, String>{
    AiTaskType.conversationTurn: 'AI 對話',
    AiTaskType.smartDistractors: '測驗智慧選項',
    AiTaskType.photoImport: '拍照建卡',
    AiTaskType.speakingScore: '口說評分',
  };

  static const _planLabels = <AiEntitlement, String>{
    AiEntitlement.free: '免費',
    AiEntitlement.plus: 'Plus',
    AiEntitlement.proAi: 'Pro AI',
    AiEntitlement.classroom: '班級',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final entitlement = ref.watch(aiEntitlementProvider);
    final quota = ref.watch(aiQuotaServiceProvider);
    final summary = AiAnalyticsService().getUsageSummary();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.insights_outlined, size: 20, color: theme.colorScheme.primary),
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

        // —— Plan selector ——
        Text('方案', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            for (final e in AiEntitlement.values)
              ChoiceChip(
                label: Text(_planLabels[e] ?? e.name),
                selected: e == entitlement,
                onSelected: (sel) {
                  if (sel) {
                    ref.read(aiEntitlementProvider.notifier).setEntitlement(e);
                  }
                },
              ),
          ],
        ),
        const SizedBox(height: 16),

        // —— Per-task daily usage ——
        Text('今日雲端用量', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        for (final entry in _meteredTasks.entries)
          _UsageRow(
            label: entry.value,
            used: quota.usageToday(entry.key),
            limit: AiQuotaPolicy.dailyLimit(entitlement, entry.key),
          ),
        const SizedBox(height: 12),

        // —— 24h token summary ——
        Text(
          summary.calls == 0
              ? '近 24 小時：尚無雲端 AI 呼叫'
              : '近 24 小時：${summary.calls} 次呼叫'
                  '（成功 ${summary.successes}）'
                  '，約 ${summary.totalTokens} tokens',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
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
            // Ticker alive, which is unnecessary here and deadlocks widget tests
            // that close Hive in teardown).
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
