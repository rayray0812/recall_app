import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recall_app/core/constants/app_constants.dart';
import 'package:recall_app/features/home/widgets/ai_usage_card.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('Recall-ai-usage-card-');
    Hive.init(tempDir.path);
    await Hive.openBox(AppConstants.hiveSettingsBox);
  });

  tearDownAll(() async {
    // The plan-switch test taps a ChoiceChip, which fires an unawaited Hive
    // write (setEntitlement). Under the widget tester's fake clock that write
    // can still be in flight here, so clear()/close() may block — guard with a
    // timeout so teardown can't hang the suite.
    try {
      await Hive.box(AppConstants.hiveSettingsBox)
          .clear()
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await Hive.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  setUp(() async {
    await Hive.box(AppConstants.hiveSettingsBox).clear();
  });

  Widget harness() => const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: AiUsageCard()),
          ),
        ),
      );

  testWidgets('renders plan chips and metered task rows', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    expect(find.text('免費'), findsOneWidget);
    expect(find.text('Pro AI'), findsOneWidget);
    expect(find.text('AI 對話'), findsOneWidget);
    expect(find.text('測驗智慧選項'), findsOneWidget);
    expect(find.text('拍照建卡'), findsOneWidget);
    // Free tier shows a finite cap for photo import (10).
    expect(find.text('0 / 10'), findsOneWidget);
  });

  testWidgets('switching to Pro AI shows unlimited quotas', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    expect(find.text('無限'), findsNothing);

    await tester.tap(find.text('Pro AI'));
    // setEntitlement flips state synchronously (drives the rebuild) then writes
    // to Hive asynchronously; pump a few frames for the provider rebuild (avoid
    // pumpAndSettle — progress bars never "settle").
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // All four metered tasks become unlimited under Pro AI.
    expect(find.text('無限'), findsNWidgets(4));

    // Flush the real async Hive write from setEntitlement so tearDownAll's
    // Hive.close() doesn't block on a pending box operation under fake-async.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  });

  // NOTE: the seeded-usage rendering path ("3 / 10") is covered at the service
  // level by ai_quota_service_test (usageToday with a pre-seeded bucket); a
  // widget test that seeds the quota then pumps the card hangs in this
  // environment, so the value isn't worth a flaky test here.
}
