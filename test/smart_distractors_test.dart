import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/services/ai/ai_capability_service.dart';
import 'package:recall_app/services/ai/ai_router.dart';
import 'package:recall_app/services/ai_task.dart';
import 'package:recall_app/services/groq_completion_service.dart';
import 'package:recall_app/services/local_ai_service.dart';

void main() {
  group('AiRouter.tierFor(smartDistractors)', () {
    test('is cloudPreferred (high-frequency → spare the battery, §2.5)', () {
      expect(
        AiRouter.tierFor(AiTaskType.smartDistractors),
        AiTaskTier.cloudPreferred,
      );
    });

    test('cloudPreferred routes to cloud when online + cloud configured', () {
      final decision = AiRouter.route(
        type: AiTaskType.smartDistractors,
        capability: const AiCapability(
          platform: AiPlatform.android,
          totalRamMb: 8000,
          appleFoundationModels: false,
        ),
        localModelReady: true,
        online: true,
        privacyMode: false,
        cloudConfigured: true,
      );
      expect(decision.target, AiRouteTarget.cloud);
    });

    test('falls back to local engine when offline', () {
      final decision = AiRouter.route(
        type: AiTaskType.smartDistractors,
        capability: const AiCapability(
          platform: AiPlatform.android,
          totalRamMb: 8000,
          appleFoundationModels: false,
        ),
        localModelReady: true,
        online: false,
        privacyMode: false,
        cloudConfigured: true,
      );
      expect(decision.target, AiRouteTarget.local);
    });
  });

  group('GroqCompletionService.buildBody', () {
    test('wraps the prompt as a single user message with the model', () {
      final body = GroqCompletionService.buildBody(
        model: 'llama-3.3-70b-versatile',
        prompt: 'hello',
        temperature: 0.8,
        maxTokens: 160,
      );
      expect(body['model'], 'llama-3.3-70b-versatile');
      expect(body['max_tokens'], 160);
      final messages = body['messages'] as List;
      expect(messages, hasLength(1));
      expect(messages.first, {'role': 'user', 'content': 'hello'});
    });
  });

  group('GroqCompletionService.parseContent', () {
    test('extracts assistant content from a chat completion body', () {
      final raw = jsonEncode({
        'choices': [
          {
            'message': {'content': '永久的\n快速的\n巨大的'},
          },
        ],
      });
      expect(GroqCompletionService.parseContent(raw), '永久的\n快速的\n巨大的');
    });

    test('returns empty string on malformed body', () {
      expect(GroqCompletionService.parseContent('not json'), '');
      expect(GroqCompletionService.parseContent('{"choices":[]}'), '');
    });
  });

  group('buildDistractorsPrompt', () {
    test('forward (term→definition) mentions term, correct option, count', () {
      final p = LocalAiService.buildDistractorsPrompt(
        term: 'ephemeral',
        definition: 'lasting a very short time',
        correctOption: '短暫的',
        reversed: false,
        count: 3,
      );
      expect(p, contains('ephemeral'));
      expect(p, contains('短暫的'));
      expect(p, contains('3'));
      // Forward questions ask for Chinese meanings of look-alike decoy words.
      expect(p, contains('繁體中文意思'));
      expect(p, contains('不可以輸出英文單字'));
      expect(p, contains('外觀相似'));
      expect(p, contains('不要只找意思相近'));
    });

    test(
      'reversed (definition→term) asks for look-alike words, excludes answer',
      () {
        final p = LocalAiService.buildDistractorsPrompt(
          term: 'ephemeral',
          definition: '短暫的',
          correctOption: 'ephemeral',
          reversed: true,
          count: 3,
        );
        expect(p, contains('短暫的'));
        expect(p, contains('ephemeral'));
        expect(p, contains('拼字相近'));
        expect(p, contains('不要產生 "ephemeral" 的同義詞'));
      },
    );
  });

  group('isDistractorShapeValid', () {
    test('forward questions only accept Chinese meanings', () {
      expect(
        LocalAiService.isDistractorShapeValid('永久的', reversed: false),
        isTrue,
      );
      expect(
        LocalAiService.isDistractorShapeValid('permanent', reversed: false),
        isFalse,
      );
    });

    test('reversed questions only accept English words', () {
      expect(
        LocalAiService.isDistractorShapeValid('permanent', reversed: true),
        isTrue,
      );
      expect(
        LocalAiService.isDistractorShapeValid('永久的', reversed: true),
        isFalse,
      );
    });
  });

  group('parseDistractorLines', () {
    test('strips numbering, bullets and quotes', () {
      const raw = '1. 永久的\n2) 快速的\n- 巨大的';
      final out = LocalAiService.parseDistractorLines(raw, exclude: '短暫的');
      expect(out, ['永久的', '快速的', '巨大的']);
    });

    test('drops the line equal to the correct answer (case-insensitive)', () {
      const raw = 'Permanent\nPERMANENT\nfast\nhuge';
      final out = LocalAiService.parseDistractorLines(
        raw,
        exclude: 'permanent',
      );
      expect(out, ['fast', 'huge']);
    });

    test('dedups case-insensitively and caps at max', () {
      const raw = '永久的\n永久的\n快速的\n巨大的\n微小的';
      final out = LocalAiService.parseDistractorLines(
        raw,
        exclude: '短暫的',
        max: 3,
      );
      expect(out, ['永久的', '快速的', '巨大的']);
    });

    test('strips an echoed 干擾選項 label and blank lines', () {
      const raw = '干擾選項：永久的\n\n快速的';
      final out = LocalAiService.parseDistractorLines(raw, exclude: '短暫的');
      expect(out, ['永久的', '快速的']);
    });

    test('returns empty for blank output', () {
      expect(
        LocalAiService.parseDistractorLines('   \n\n', exclude: 'x'),
        isEmpty,
      );
    });
  });
}
