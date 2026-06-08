import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/features/home/widgets/ai_usage_card.dart';
import 'package:recall_app/services/ai/ai_entitlement.dart';
import 'package:recall_app/services/ai/ai_quota_policy.dart';
import 'package:recall_app/services/ai_analytics_service.dart';
import 'package:recall_app/services/ai_task.dart';

// The card reads everything from [aiUsageViewProvider], so tests inject a fake
// view and never touch Hive — fast, deterministic, no lifecycle flakiness.
AiUsageView _view({
  AiEntitlement entitlement = AiEntitlement.free,
  Map<AiTaskType, int> used = const {},
  AiUsageSummary summary = const AiUsageSummary(),
}) {
  return AiUsageView(
    entitlement: entitlement,
    rows: [
      for (final task in const [
        AiTaskType.conversationTurn,
        AiTaskType.smartDistractors,
        AiTaskType.photoImport,
        AiTaskType.speakingScore,
      ])
        AiUsageRow(
          task: task,
          label: switch (task) {
            AiTaskType.conversationTurn => 'AI 對話',
            AiTaskType.smartDistractors => '測驗智慧選項',
            AiTaskType.photoImport => '拍照建卡',
            AiTaskType.speakingScore => '口說評分',
            _ => task.name,
          },
          used: used[task] ?? 0,
          limit: AiQuotaPolicy.dailyLimit(entitlement, task),
        ),
    ],
    summary: summary,
  );
}

Widget _harness(AiUsageView view) => ProviderScope(
      overrides: [aiUsageViewProvider.overrideWithValue(view)],
      child: const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: AiUsageCard())),
      ),
    );

void main() {
  testWidgets('renders metered task rows with free-tier limits', (tester) async {
    await tester.pumpWidget(_harness(_view()));
    await tester.pump();

    expect(find.text('AI 對話'), findsOneWidget);
    expect(find.text('測驗智慧選項'), findsOneWidget);
    expect(find.text('拍照建卡'), findsOneWidget);
    expect(find.text('0 / 10'), findsOneWidget); // photoImport free cap = 10
  });

  testWidgets('reflects already-consumed usage', (tester) async {
    await tester.pumpWidget(
      _harness(_view(used: {AiTaskType.photoImport: 3})),
    );
    await tester.pump();

    expect(find.text('3 / 10'), findsOneWidget);
  });

  testWidgets('Pro AI shows unlimited quotas', (tester) async {
    await tester.pumpWidget(_harness(_view(entitlement: AiEntitlement.proAi)));
    await tester.pump();

    expect(find.text('無限'), findsNWidgets(4));
  });

  testWidgets('shows the 24h token summary when there is usage', (tester) async {
    await tester.pumpWidget(
      _harness(_view(
        summary: const AiUsageSummary(
          calls: 2,
          successes: 2,
          inputTokens: 100,
          outputTokens: 50,
        ),
      )),
    );
    await tester.pump();

    expect(find.textContaining('2 次呼叫'), findsOneWidget);
    expect(find.textContaining('150 tokens'), findsOneWidget);
  });
}
