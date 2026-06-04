import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/services/ai/ai_router.dart';
import 'package:recall_app/services/ai_task.dart';
import 'package:recall_app/services/local_ai_service.dart';

void main() {
  group('AiRouter.tierFor(smartDistractors)', () {
    test('is localOnly (privacy-sensitive, on-device)', () {
      expect(
        AiRouter.tierFor(AiTaskType.smartDistractors),
        AiTaskTier.localOnly,
      );
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
      // Forward questions ask for a Chinese meaning.
      expect(p, contains('意思'));
    });

    test('reversed (definition→term) asks for similar words, excludes answer',
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
      expect(p, contains('單字'));
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
      final out =
          LocalAiService.parseDistractorLines(raw, exclude: 'permanent');
      expect(out, ['fast', 'huge']);
    });

    test('dedups case-insensitively and caps at max', () {
      const raw = '永久的\n永久的\n快速的\n巨大的\n微小的';
      final out =
          LocalAiService.parseDistractorLines(raw, exclude: '短暫的', max: 3);
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
