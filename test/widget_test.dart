import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/models/flashcard.dart';
import 'package:recall_app/models/study_set.dart';
import 'package:recall_app/models/card_progress.dart';
import 'package:recall_app/models/review_log.dart';
import 'package:recall_app/models/review_session.dart';
import 'package:recall_app/services/ai_error.dart';
import 'package:recall_app/services/ai_task.dart';
import 'package:recall_app/services/fsrs_service.dart';
import 'package:recall_app/services/local_ai_service.dart';
import 'package:recall_app/services/outcome_adapter.dart';
import 'package:recall_app/services/supabase_service.dart';

void main() {
  test('StudySet can be created with cards', () {
    final set = StudySet(
      id: 'test-id',
      title: 'Test Set',
      createdAt: DateTime(2024, 1, 1),
      cards: [
        const Flashcard(id: '1', term: 'Hello', definition: 'World'),
        const Flashcard(id: '2', term: 'Foo', definition: 'Bar'),
      ],
    );

    expect(set.cards.length, 2);
    expect(set.title, 'Test Set');
    expect(set.isSynced, false);
  });

  test('Flashcard default difficulty is 0', () {
    const card = Flashcard(id: '1', term: 'A', definition: 'B');
    expect(card.difficultyLevel, 0);
  });

  test('Flashcard supports tags', () {
    const card = Flashcard(
      id: '1',
      term: 'A',
      definition: 'B',
      tags: ['vocab', 'chapter1'],
    );
    expect(card.tags, ['vocab', 'chapter1']);
  });

  test('Flashcard default tags is empty', () {
    const card = Flashcard(id: '1', term: 'A', definition: 'B');
    expect(card.tags, isEmpty);
  });

  group('CardProgress', () {
    test('can be created with defaults', () {
      const progress = CardProgress(cardId: 'c1', setId: 's1');
      expect(progress.stability, 0.0);
      expect(progress.difficulty, 0.0);
      expect(progress.reps, 0);
      expect(progress.lapses, 0);
      expect(progress.state, 0); // New
      expect(progress.lastReview, isNull);
      expect(progress.due, isNull);
      expect(progress.isSynced, false);
    });

    test('copyWith preserves unmodified fields', () {
      const progress = CardProgress(cardId: 'c1', setId: 's1');
      final updated = progress.copyWith(stability: 5.0, reps: 1);
      expect(updated.cardId, 'c1');
      expect(updated.setId, 's1');
      expect(updated.stability, 5.0);
      expect(updated.reps, 1);
      expect(updated.difficulty, 0.0);
    });

    test('serializes to/from JSON', () {
      final now = DateTime.utc(2024, 6, 15);
      final progress = CardProgress(
        cardId: 'c1',
        setId: 's1',
        stability: 10.5,
        difficulty: 4.2,
        reps: 3,
        state: 2,
        lastReview: now,
        due: now.add(const Duration(days: 5)),
      );
      final json = progress.toJson();
      final restored = CardProgress.fromJson(json);
      expect(restored.cardId, 'c1');
      expect(restored.stability, 10.5);
      expect(restored.state, 2);
    });
  });

  group('ReviewLog', () {
    test('can be created', () {
      final log = ReviewLog(
        id: 'log1',
        cardId: 'c1',
        setId: 's1',
        rating: 3,
        state: 0,
        reviewedAt: DateTime.utc(2024, 6, 15),
      );
      expect(log.rating, 3);
      expect(log.state, 0);
    });

    test('serializes to/from JSON', () {
      final log = ReviewLog(
        id: 'log1',
        cardId: 'c1',
        setId: 's1',
        rating: 4,
        state: 2,
        reviewedAt: DateTime.utc(2024, 6, 15),
        lastStability: 5.0,
        lastDifficulty: 3.0,
      );
      final json = log.toJson();
      final restored = ReviewLog.fromJson(json);
      expect(restored.rating, 4);
      expect(restored.lastStability, 5.0);
    });
  });

  group('FsrsService', () {
    late FsrsService service;

    setUp(() {
      service = FsrsService();
    });

    test('reviewCard updates a new card', () {
      const progress = CardProgress(cardId: 'c1', setId: 's1');
      final result = service.reviewCard(progress, 3); // Good

      expect(result.progress.reps, 1);
      expect(result.progress.stability, greaterThan(0));
      expect(result.progress.difficulty, greaterThan(0));
      expect(result.progress.lastReview, isNotNull);
      expect(result.progress.due, isNotNull);

      expect(result.log.cardId, 'c1');
      expect(result.log.setId, 's1');
      expect(result.log.rating, 3);
      expect(result.log.state, 0); // was New before review
    });

    test('reviewCard with Again increments lapses', () {
      const progress = CardProgress(cardId: 'c1', setId: 's1');
      final result = service.reviewCard(progress, 1); // Again

      expect(result.progress.lapses, 1);
    });

    test('reviewCard with Easy on new card', () {
      const progress = CardProgress(cardId: 'c1', setId: 's1');
      final result = service.reviewCard(progress, 4); // Easy

      expect(result.progress.reps, 1);
      expect(result.progress.due, isNotNull);
      // Easy should give a longer interval than Again
      expect(result.progress.due!.isAfter(DateTime.now().toUtc()), isTrue);
    });

    test('getSchedulingPreview returns 4 entries', () {
      const progress = CardProgress(cardId: 'c1', setId: 's1');
      final preview = service.getSchedulingPreview(progress);

      expect(preview.length, 4);
      expect(preview.keys, containsAll([1, 2, 3, 4]));
      // Each should be a non-empty string
      for (final v in preview.values) {
        expect(v, isNotEmpty);
      }
    });

    test('getRetrievability for new card is 0', () {
      const progress = CardProgress(cardId: 'c1', setId: 's1');
      expect(service.getRetrievability(progress), 0.0);
    });

    test('multiple reviews increase reps', () {
      const progress = CardProgress(cardId: 'c1', setId: 's1');
      final r1 = service.reviewCard(progress, 3);
      final r2 = service.reviewCard(r1.progress, 3);
      expect(r2.progress.reps, 2);
    });

    test('toFsrsCardId is stable for same card id', () {
      final a = FsrsService.toFsrsCardId('card-abc-123');
      final b = FsrsService.toFsrsCardId('card-abc-123');
      expect(a, b);
      expect(a, greaterThanOrEqualTo(0));
    });

    test('toFsrsCardId differs for different ids', () {
      final a = FsrsService.toFsrsCardId('card-a');
      final b = FsrsService.toFsrsCardId('card-b');
      expect(a, isNot(b));
    });

    test('reviewCard throws for invalid rating', () {
      const progress = CardProgress(cardId: 'c1', setId: 's1');
      expect(() => service.reviewCard(progress, 0), throwsArgumentError);
      expect(() => service.reviewCard(progress, 5), throwsArgumentError);
    });
  });

  group('AiErrorClassifier.classifySdkError', () {
    test('quota / rate-limit messages → quotaExceeded', () {
      expect(
        AiErrorClassifier.classifySdkError('quota exceeded'),
        ScanFailureReason.quotaExceeded,
      );
      expect(
        AiErrorClassifier.classifySdkError('429 Too Many Requests'),
        ScanFailureReason.quotaExceeded,
      );
      expect(
        AiErrorClassifier.classifySdkError('RESOURCE_EXHAUSTED'),
        ScanFailureReason.quotaExceeded,
      );
      expect(
        AiErrorClassifier.classifySdkError('too many requests from client'),
        ScanFailureReason.quotaExceeded,
      );
    });

    test('auth messages → authError', () {
      expect(
        AiErrorClassifier.classifySdkError('API key not valid'),
        ScanFailureReason.authError,
      );
      expect(
        AiErrorClassifier.classifySdkError('UNAUTHENTICATED request'),
        ScanFailureReason.authError,
      );
      expect(
        AiErrorClassifier.classifySdkError('permission denied'),
        ScanFailureReason.authError,
      );
    });

    test('server error messages → serverError', () {
      expect(
        AiErrorClassifier.classifySdkError('500 internal server error'),
        ScanFailureReason.serverError,
      );
      expect(
        AiErrorClassifier.classifySdkError('service unavailable 503'),
        ScanFailureReason.serverError,
      );
    });

    test('unknown message → unknown', () {
      expect(
        AiErrorClassifier.classifySdkError('something totally random'),
        ScanFailureReason.unknown,
      );
    });
  });

  group('AiErrorClassifier.classifyHttpError', () {
    test('status 429 → quotaExceeded', () {
      expect(
        AiErrorClassifier.classifyHttpError(429, ''),
        ScanFailureReason.quotaExceeded,
      );
    });

    test('status 401/403 → authError', () {
      expect(
        AiErrorClassifier.classifyHttpError(401, ''),
        ScanFailureReason.authError,
      );
      expect(
        AiErrorClassifier.classifyHttpError(403, 'forbidden'),
        ScanFailureReason.authError,
      );
    });

    test('status 400 → invalidRequest', () {
      expect(
        AiErrorClassifier.classifyHttpError(400, 'bad request'),
        ScanFailureReason.invalidRequest,
      );
    });

    test('status 5xx → serverError', () {
      expect(
        AiErrorClassifier.classifyHttpError(500, ''),
        ScanFailureReason.serverError,
      );
      expect(
        AiErrorClassifier.classifyHttpError(503, 'service unavailable'),
        ScanFailureReason.serverError,
      );
    });

    test('isRateLimit returns true only for quotaExceeded', () {
      expect(
        AiErrorClassifier.isRateLimit(ScanFailureReason.quotaExceeded),
        isTrue,
      );
      expect(
        AiErrorClassifier.isRateLimit(ScanFailureReason.authError),
        isFalse,
      );
      expect(AiErrorClassifier.isRateLimit(ScanFailureReason.unknown), isFalse);
    });
  });

  group('LocalAiService prompts', () {
    test('buildReviewHintPrompt mentions term and forbids definition', () {
      final prompt = LocalAiService.buildReviewHintPrompt(
        term: 'ephemeral',
        definition: '短暫的',
      );
      expect(prompt, contains('ephemeral'));
      expect(prompt, contains('短暫的'));
      expect(prompt, contains('不要直接說出意思'));
    });

    test('buildMnemonicPrompt asks for mnemonic only', () {
      final prompt = LocalAiService.buildMnemonicPrompt(
        term: 'serendipity',
        definition: '意外的好運',
      );
      expect(prompt, contains('serendipity'));
      expect(prompt, contains('口訣'));
      expect(prompt, contains('意外的好運'));
    });

    test('buildConfusionPrompt frames target vs chosen wrong', () {
      final prompt = LocalAiService.buildConfusionPrompt(
        targetTerm: 'affect',
        targetDefinition: '影響（動詞）',
        chosenTerm: 'effect',
        chosenDefinition: '結果（名詞）',
      );
      expect(prompt, contains('affect'));
      expect(prompt, contains('effect'));
      expect(prompt, contains('正確'));
      expect(prompt, contains('誤選'));
    });

    test('buildExampleSentencePrompt requires the term in the sentence', () {
      final prompt = LocalAiService.buildExampleSentencePrompt(
        term: 'resilient',
        definition: '有韌性的',
      );
      expect(prompt, contains('resilient'));
      expect(prompt, contains('例句'));
      expect(prompt, contains('不要附中文翻譯'));
    });
  });

  group('LocalAiService cleaners', () {
    test('cleanSingleSentence strips leading "提示：" label', () {
      expect(LocalAiService.cleanSingleSentence('提示：這個字常用於正式場合'), '這個字常用於正式場合');
    });

    test('cleanSingleSentence strips Hint: label', () {
      expect(
        LocalAiService.cleanSingleSentence('Hint: think of a butterfly'),
        'think of a butterfly',
      );
    });

    test('cleanSingleSentence strips 例句/Example labels', () {
      expect(
        LocalAiService.cleanSingleSentence('例句：She is very resilient.'),
        'She is very resilient.',
      );
      expect(
        LocalAiService.cleanSingleSentence('Example: I feel happy today.'),
        'I feel happy today.',
      );
    });

    test('cleanSingleSentence keeps only first paragraph', () {
      expect(
        LocalAiService.cleanSingleSentence('first line\nsecond line\nthird'),
        'first line',
      );
    });

    test('cleanSingleSentence strips Qwen thinking blocks', () {
      expect(
        LocalAiService.cleanSingleSentence(
          '<think>\nI should make a sentence.\n</think>\nExample: She is resilient.',
        ),
        'She is resilient.',
      );
      expect(
        LocalAiService.cleanSingleSentence(
          '<think>\nThe user wants an example.\nExample: I am busy today.',
        ),
        '',
      );
      expect(LocalAiService.cleanSingleSentence('think'), '');
    });

    test('cleanSingleSentence strips surrounding quotes', () {
      expect(
        LocalAiService.cleanSingleSentence('"quoted hint"'),
        'quoted hint',
      );
      expect(LocalAiService.cleanSingleSentence('「中文引號」'), '中文引號');
    });

    test(
      'cleanSingleSentence trims whitespace and returns empty for empty input',
      () {
        expect(LocalAiService.cleanSingleSentence('   \n  '), '');
        expect(LocalAiService.cleanSingleSentence(''), '');
      },
    );

    test('cleanShortParagraph keeps up to two non-empty lines', () {
      expect(
        LocalAiService.cleanShortParagraph('one\ntwo\nthree\nfour'),
        'one\ntwo',
      );
    });

    test('cleanShortParagraph strips numbered/bullet markers', () {
      expect(
        LocalAiService.cleanShortParagraph('1. first point\n2. second point'),
        'first point\nsecond point',
      );
      expect(
        LocalAiService.cleanShortParagraph('• item one\n• item two'),
        'item one\nitem two',
      );
    });
  });

  group('AiTaskState', () {
    test('AiTaskIdle is the initial state', () {
      const state = AiTaskIdle<List<String>>();
      expect(state, isA<AiTaskState<List<String>>>());
    });

    test('AiTaskRunning carries a hint', () {
      const state = AiTaskRunning<List<String>>(hint: '分析圖片中...');
      expect(state.hint, '分析圖片中...');
    });

    test('AiTaskDone carries result and elapsed', () {
      final state = AiTaskDone<int>(42, elapsed: const Duration(seconds: 2));
      expect(state.result, 42);
      expect(state.elapsed.inSeconds, 2);
    });

    test('AiTaskError carries reason and message', () {
      const state = AiTaskError<int>(
        reason: ScanFailureReason.quotaExceeded,
        message: 'Rate limit hit',
        elapsed: Duration(milliseconds: 500),
      );
      expect(state.reason, ScanFailureReason.quotaExceeded);
      expect(state.message, 'Rate limit hit');
    });
  });

  group('OutcomeAdapter', () {
    test('conversationSuccess resolves to ApplyFsrsRating(3)', () {
      final action = OutcomeAdapter.resolve(
        ConversationOutcome.conversationSuccess,
      );
      expect(action, isA<ApplyFsrsRating>());
      expect((action as ApplyFsrsRating).rating, 3);
    });

    test('conversationUnusedTerm resolves to ApplyFsrsRating(1)', () {
      final action = OutcomeAdapter.resolve(
        ConversationOutcome.conversationUnusedTerm,
      );
      expect(action, isA<ApplyFsrsRating>());
      expect((action as ApplyFsrsRating).rating, 1);
    });

    test('speakingTargetUsed resolves to ApplyFsrsRating(3)', () {
      final action = OutcomeAdapter.resolve(
        ConversationOutcome.speakingTargetUsed,
      );
      expect(action, isA<ApplyFsrsRating>());
      expect((action as ApplyFsrsRating).rating, 3);
    });

    test('quizConfusionDetected resolves to NoScheduleImpact', () {
      final action = OutcomeAdapter.resolve(
        ConversationOutcome.quizConfusionDetected,
      );
      expect(action, isA<NoScheduleImpact>());
    });
  });

  group('ReviewSession', () {
    test('can be created with defaults', () {
      final session = ReviewSession(
        id: 'sess-1',
        userId: 'user-1',
        modality: 'conversation',
        startedAt: DateTime.utc(2026, 4, 27, 10),
      );
      expect(session.itemCount, 0);
      expect(session.completedCount, 0);
      expect(session.scoreAvg, isNull);
      expect(session.isSynced, isFalse);
    });

    test('copyWith updates fields', () {
      final session = ReviewSession(
        id: 'sess-2',
        userId: 'user-1',
        modality: 'srs',
        startedAt: DateTime.utc(2026, 4, 27, 9),
        itemCount: 5,
      );
      final updated = session.copyWith(completedCount: 5, scoreAvg: 87.5);
      expect(updated.completedCount, 5);
      expect(updated.scoreAvg, 87.5);
      expect(updated.itemCount, 5); // unchanged
    });

    test('serializes to/from JSON round-trip', () {
      final session = ReviewSession(
        id: 'sess-3',
        userId: 'user-1',
        modality: 'quiz',
        startedAt: DateTime.utc(2026, 4, 27, 8),
        endedAt: DateTime.utc(2026, 4, 27, 8, 5),
        itemCount: 10,
        completedCount: 8,
        scoreAvg: 72.0,
        isSynced: true,
      );
      final json = session.toJson();
      final restored = ReviewSession.fromJson(json);
      expect(restored.id, session.id);
      expect(restored.modality, session.modality);
      expect(restored.completedCount, session.completedCount);
      expect(restored.scoreAvg, session.scoreAvg);
    });
  });

  group('ReviewLog Phase A fields', () {
    test('new optional fields default to null', () {
      final log = ReviewLog(
        id: 'log-1',
        cardId: 'c1',
        setId: 's1',
        rating: 3,
        state: 2,
        reviewedAt: DateTime.utc(2026, 4, 27),
      );
      expect(log.sessionId, isNull);
      expect(log.responseLatencyMs, isNull);
      expect(log.chosenDistractorId, isNull);
      expect(log.predictedRetrievability, isNull);
      expect(log.metadata, isNull);
    });

    test('round-trip through supabase_service mapper preserves new fields', () {
      final log = ReviewLog(
        id: 'log-2',
        cardId: 'c2',
        setId: 's1',
        rating: 2,
        state: 1,
        reviewedAt: DateTime.utc(2026, 4, 27, 12),
        reviewType: 'conversation',
        speakingScore: 85,
        sessionId: 'sess-abc',
        responseLatencyMs: 1200,
        chosenDistractorId: 'card-xyz',
        predictedRetrievability: 0.82,
        metadata: {'source': 'test'},
      );

      const userId = 'user-42';
      final row = SupabaseService.reviewLogToRow(log, userId);

      expect(row['session_id'], 'sess-abc');
      expect(row['response_latency_ms'], 1200);
      expect(row['chosen_distractor_id'], 'card-xyz');
      expect(row['predicted_retrievability'], closeTo(0.82, 0.001));
      expect(row['metadata'], {'source': 'test'});

      // Simulate reading back from Supabase (row already has user_id stripped)
      final rowForRead = Map<String, dynamic>.from(row)
        ..['card_id'] = row['card_id']
        ..['set_id'] = row['set_id']
        ..['reviewed_at'] = row['reviewed_at']
        ..['elapsed_days'] = 0
        ..['scheduled_days'] = 0
        ..['last_stability'] = 0.0
        ..['last_difficulty'] = 0.0;
      final restored = SupabaseService.rowToReviewLog(rowForRead);

      expect(restored.sessionId, 'sess-abc');
      expect(restored.responseLatencyMs, 1200);
      expect(restored.chosenDistractorId, 'card-xyz');
      expect(restored.predictedRetrievability, closeTo(0.82, 0.001));
      expect(restored.metadata, {'source': 'test'});
    });

    test('legacy row without new fields reads back with nulls', () {
      final legacyRow = {
        'id': 'log-3',
        'card_id': 'c3',
        'set_id': 's1',
        'rating': 3,
        'state': 2,
        'reviewed_at': '2026-04-27T00:00:00.000Z',
        'review_type': 'srs',
        'elapsed_days': 1,
        'scheduled_days': 7,
        'last_stability': 4.5,
        'last_difficulty': 5.0,
        // no session_id, response_latency_ms, etc.
      };
      final log = SupabaseService.rowToReviewLog(legacyRow);
      expect(log.sessionId, isNull);
      expect(log.responseLatencyMs, isNull);
      expect(log.chosenDistractorId, isNull);
      expect(log.predictedRetrievability, isNull);
    });
  });
}
