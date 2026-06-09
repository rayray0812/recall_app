import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recall_app/core/constants/app_constants.dart';
import 'package:recall_app/services/ai/ai_entitlement.dart';
import 'package:recall_app/services/ai/ai_quota_policy.dart';
import 'package:recall_app/services/ai/ai_quota_service.dart';
import 'package:recall_app/services/ai_task.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('Recall-ai-quota-');
    Hive.init(tempDir.path);
    await Hive.openBox(AppConstants.hiveSettingsBox);
  });

  tearDownAll(() async {
    await Hive.box(AppConstants.hiveSettingsBox).clear();
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  setUp(() async {
    await Hive.box(AppConstants.hiveSettingsBox).clear();
  });

  test('tryConsume increments usage for a metered task', () async {
    final svc = AiQuotaService();
    expect(svc.usageToday(AiTaskType.photoImport), 0);

    expect(
      await svc.tryConsume(AiEntitlement.free, AiTaskType.photoImport),
      isTrue,
    );
    expect(svc.usageToday(AiTaskType.photoImport), 1);
  });

  test('recordServerUsage mirrors app-remote proxy usage for display',
      () async {
    final svc = AiQuotaService();
    expect(svc.usageToday(AiTaskType.smartDistractors), 0);

    await svc.recordServerUsage(AiTaskType.smartDistractors);

    expect(svc.usageToday(AiTaskType.smartDistractors), 1);
  });

  test('tryConsume never consumes (and always allows) unmetered local tasks',
      () async {
    final svc = AiQuotaService();
    for (var i = 0; i < 5; i++) {
      expect(
        await svc.tryConsume(AiEntitlement.free, AiTaskType.reviewHint),
        isTrue,
      );
    }
    expect(svc.usageToday(AiTaskType.reviewHint), 0);
  });

  test('tryConsume blocks once the daily cap is reached', () async {
    final svc = AiQuotaService();
    const e = AiEntitlement.free;
    const t = AiTaskType.photoImport; // free cap = 10
    final cap = AiQuotaPolicy.dailyLimit(e, t);

    for (var i = 0; i < cap; i++) {
      expect(await svc.tryConsume(e, t), isTrue, reason: 'call ${i + 1}');
    }
    // Cap reached → further calls blocked, usage stays at the cap.
    expect(await svc.tryConsume(e, t), isFalse);
    expect(svc.usageToday(t), cap);
    expect(svc.remaining(e, t), 0);
  });

  test('concurrent tryConsume never exceeds the cap (atomic)', () async {
    final svc = AiQuotaService();
    const e = AiEntitlement.free;
    const t = AiTaskType.photoImport; // cap = 10
    final cap = AiQuotaPolicy.dailyLimit(e, t);

    // Fire many more requests than the cap, all at once.
    final results = await Future.wait([
      for (var i = 0; i < cap * 3; i++) svc.tryConsume(e, t),
    ]);

    final granted = results.where((ok) => ok).length;
    expect(granted, cap, reason: 'exactly cap requests should be granted');
    expect(svc.usageToday(t), cap, reason: 'usage must never exceed the cap');
  });

  test('unlimited tier is never blocked', () async {
    final svc = AiQuotaService();
    for (var i = 0; i < 50; i++) {
      expect(
        await svc.tryConsume(AiEntitlement.proAi, AiTaskType.conversationTurn),
        isTrue,
      );
    }
  });

  test('usage resets when the stored bucket is from a previous day', () async {
    // Seed a stale bucket (yesterday) directly.
    await Hive.box(AppConstants.hiveSettingsBox).put(
      AppConstants.settingAiQuotaKey,
      {
        'day': '2000-01-01',
        'counts': {AiTaskType.photoImport.name: 9},
      },
    );
    final svc = AiQuotaService();
    // A new service reading today sees zero, not the stale 9.
    expect(svc.usageToday(AiTaskType.photoImport), 0);
  });
}
