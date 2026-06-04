import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/features/study/services/conversation_scorer.dart';

void main() {
  group('buildScoringPrompt', () {
    test('includes the exchange, scene, level and practice words', () {
      final p = ConversationScorer.buildScoringPrompt(
        aiQuestion: 'What size do you need?',
        userResponse: 'I need a medium.',
        scenarioTitle: 'Buying shoes',
        difficulty: 'medium',
        targetTerms: ['size', 'refund'],
      );
      expect(p, contains('What size do you need?'));
      expect(p, contains('I need a medium.'));
      expect(p, contains('Buying shoes'));
      expect(p, contains('size, refund'));
      // Asks for actionable, non-empty correction (the key fix).
      expect(p, contains('Never leave this empty'));
      expect(p, contains('grammarNote'));
    });
  });

  group('parseFeedback', () {
    test('parses a clean JSON payload', () {
      final fb = ConversationScorer.parseFeedback(
        '{"grammar":4,"vocabulary":3,"relevance":5,'
        '"correction":"I need a medium, please.","grammarNote":"Add please."}',
      );
      expect(fb, isNotNull);
      expect(fb!.grammarScore, 4);
      expect(fb.vocabScore, 3);
      expect(fb.relevanceScore, 5);
      expect(fb.correction, 'I need a medium, please.');
      expect(fb.grammarNote, 'Add please.');
    });

    test('clamps out-of-range scores', () {
      final fb = ConversationScorer.parseFeedback(
        '{"grammar":9,"vocabulary":-2,"relevance":3}',
      );
      expect(fb!.grammarScore, 5);
      expect(fb.vocabScore, 0);
    });

    test('returns null on non-JSON', () {
      expect(ConversationScorer.parseFeedback('totally not json'), isNull);
    });
  });

  group('evaluateOffline gives actionable feedback (never blank)', () {
    test('very short answer suggests a full sentence', () {
      final fb = ConversationScorer.evaluateOffline(
        userResponse: 'Yes.',
        targetTerms: const ['refund'],
      );
      expect(fb.grammarNote, isNotEmpty);
      expect(fb.grammarNote.toLowerCase(), contains('full sentence'));
    });

    test('longer answer without practice words nudges vocabulary use', () {
      final fb = ConversationScorer.evaluateOffline(
        userResponse: 'I would really like to go there sometime soon today.',
        targetTerms: const ['refund', 'receipt'],
      );
      expect(fb.grammarNote, isNotEmpty);
    });
  });
}
