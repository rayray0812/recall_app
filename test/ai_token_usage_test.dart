import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recall_app/core/constants/app_constants.dart';
import 'package:recall_app/services/ai/ai_token_estimator.dart';
import 'package:recall_app/services/ai_analytics_service.dart';
import 'package:recall_app/services/ai_task.dart';

void main() {
  group('AiTokenEstimator', () {
    test('empty string is zero tokens', () {
      expect(AiTokenEstimator.estimate(''), 0);
    });

    test('English text ~ 4 chars per token', () {
      // 8 ASCII chars → ceil(8/4) = 2.
      expect(AiTokenEstimator.estimate('abcdefgh'), 2);
    });

    test('CJK counts ~1 token per character (denser than English)', () {
      // 4 Han chars → 4 tokens, far more than 4 ASCII chars (1 token).
      expect(AiTokenEstimator.estimate('短暫永久'), 4);
      expect(
        AiTokenEstimator.estimate('短暫永久'),
        greaterThan(AiTokenEstimator.estimate('abcd')),
      );
    });

    test('estimateAll sums the parts', () {
      expect(
        AiTokenEstimator.estimateAll(['abcd', '短暫']),
        AiTokenEstimator.estimate('abcd') + AiTokenEstimator.estimate('短暫'),
      );
    });
  });

  group('AiAnalyticsService usage events', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('Recall-ai-usage-');
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

    test('logEvent stores token estimates only when non-zero', () async {
      final svc = AiAnalyticsService();
      await svc.logEvent(
        taskType: AiTaskType.smartDistractors,
        provider: 'groq',
        success: true,
        elapsed: const Duration(milliseconds: 100),
        inputTokens: 30,
        outputTokens: 12,
      );
      await svc.logEvent(
        taskType: AiTaskType.reviewHint,
        provider: 'gemma',
        success: true,
        elapsed: const Duration(milliseconds: 50),
      );

      final events = svc.getRecentEvents();
      // Newest first: the local task with no tokens omits the fields.
      expect(events.first['in_tokens'], isNull);
      expect(events.first['out_tokens'], isNull);
      expect(events[1]['in_tokens'], 30);
      expect(events[1]['out_tokens'], 12);
    });

    test('getUsageSummary aggregates calls, successes and tokens per provider',
        () async {
      final svc = AiAnalyticsService();
      await svc.logEvent(
        taskType: AiTaskType.smartDistractors,
        provider: 'groq',
        success: true,
        elapsed: const Duration(milliseconds: 10),
        inputTokens: 20,
        outputTokens: 5,
      );
      await svc.logEvent(
        taskType: AiTaskType.conversationTurn,
        provider: 'groq',
        success: false,
        elapsed: const Duration(milliseconds: 10),
        inputTokens: 100,
        outputTokens: 0,
      );
      await svc.logEvent(
        taskType: AiTaskType.photoImport,
        provider: 'gemini',
        success: true,
        elapsed: const Duration(milliseconds: 10),
        inputTokens: 40,
        outputTokens: 30,
      );

      final s = svc.getUsageSummary();
      expect(s.calls, 3);
      expect(s.successes, 2);
      expect(s.failures, 1);
      expect(s.inputTokens, 160);
      expect(s.outputTokens, 35);
      expect(s.totalTokens, 195);
      expect(s.perProvider['groq']!.calls, 2);
      expect(s.perProvider['groq']!.totalTokens, 125);
      expect(s.perProvider['gemini']!.totalTokens, 70);
    });

    test('getUsageSummary ignores events outside the time window', () async {
      // Seed an old event directly into the box.
      await Hive.box(AppConstants.hiveSettingsBox).put(
        AppConstants.settingAiEventsKey,
        [
          {
            'at': DateTime.utc(2000, 1, 1).toIso8601String(),
            'task': AiTaskType.smartDistractors.name,
            'provider': 'groq',
            'result': 'success',
            'elapsed_ms': 10,
            'in_tokens': 999,
          },
        ],
      );
      final s = AiAnalyticsService().getUsageSummary(hours: 24);
      expect(s.calls, 0);
      expect(s.inputTokens, 0);
    });
  });
}
