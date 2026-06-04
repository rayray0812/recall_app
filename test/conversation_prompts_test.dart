import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/features/study/services/conversation_prompts.dart';

void main() {
  group('buildConversationSystemPrompt', () {
    String build({
      String difficulty = 'medium',
      List<String> words = const ['refund', 'receipt'],
      String adaptiveHint = '',
    }) {
      return buildConversationSystemPrompt(
        aiRole: 'Store Clerk',
        userRole: 'Customer',
        scenarioTitle: 'Returning a jacket',
        scenarioSetting: 'A clothing store counter',
        difficulty: difficulty,
        targetWords: words,
        totalTurns: 6,
        currentTurn: 2,
        adaptiveHint: adaptiveHint,
      );
    }

    test('includes role, scene and target words', () {
      final p = build();
      expect(p, contains('Store Clerk'));
      expect(p, contains('Customer'));
      expect(p, contains('Returning a jacket'));
      expect(p, contains('refund, receipt'));
    });

    test('emphasises natural, non-forced word use (not the old rigid rules)',
        () {
      final p = build();
      expect(p.toLowerCase(), contains('natural'));
      expect(p, contains('ONLY when they fit'));
      // The old robotic rules must be gone.
      expect(p, isNot(contains('Output exactly two lines')));
      expect(p, isNot(contains('MUST include')));
    });

    test('applies the difficulty profile', () {
      expect(build(difficulty: 'easy'), contains('EASY'));
      expect(build(difficulty: 'hard'), contains('HARD'));
      expect(build(difficulty: 'medium'), contains('MEDIUM'));
    });

    test('appends adaptive hint when provided, omits when blank', () {
      expect(build(adaptiveHint: 'Push harder.'), contains('Push harder.'));
      expect(build(adaptiveHint: ''), isNot(contains('Push harder.')));
    });

    test('handles empty target words gracefully', () {
      final p = build(words: const []);
      expect(p, contains('(none)'));
    });
  });

  group('buildTurnUserMessage', () {
    test('first turn is a kickoff naming the role', () {
      final m = buildTurnUserMessage(isFirstTurn: true, aiRole: 'Barista');
      expect(m.toLowerCase(), contains('begin the scene'));
      expect(m, contains('Barista'));
    });

    test('normal turn passes the trimmed student text', () {
      final m = buildTurnUserMessage(
        isFirstTurn: false,
        aiRole: 'Barista',
        studentText: '  I want a latte  ',
      );
      expect(m, 'I want a latte');
    });
  });

  group('cleanAiTurnText', () {
    test('strips a leading "Question:" label', () {
      expect(cleanAiTurnText('Question: What size?'), 'What size?');
    });

    test('strips a leading role prefix', () {
      expect(
        cleanAiTurnText('Barista: What can I get you?', aiRole: 'Barista'),
        'What can I get you?',
      );
    });

    test('drops a trailing legacy Reply hint block', () {
      final out = cleanAiTurnText(
        'Sure, what size do you want?\nReply hint: Start with "I want..."',
      );
      expect(out, 'Sure, what size do you want?');
    });

    test('strips wrapping quotes but keeps multi-sentence prose', () {
      final out = cleanAiTurnText('"Nice choice. What else can I get you?"');
      expect(out, 'Nice choice. What else can I get you?');
    });

    test('empty input → empty output', () {
      expect(cleanAiTurnText('   '), '');
    });
  });
}
