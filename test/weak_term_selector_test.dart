import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/features/study/utils/vocabulary_tracker.dart';
import 'package:recall_app/features/study/utils/weak_term_selector.dart';
import 'package:recall_app/models/card_progress.dart';

CardProgress _p({
  String id = 'c',
  double stability = 100,
  double difficulty = 1,
  int lapses = 0,
  int state = 2,
  DateTime? due,
}) {
  return CardProgress(
    cardId: id,
    setId: 's',
    stability: stability,
    difficulty: difficulty,
    lapses: lapses,
    state: state,
    due: due,
  );
}

void main() {
  final now = DateTime.utc(2026, 6, 4);

  group('termWeaknessScore', () {
    test('null progress gets a mild positive baseline', () {
      expect(termWeaknessScore(null, now), 1.5);
    });

    test('a strong card (stable, easy, no lapses, not due) scores low', () {
      final s = termWeaknessScore(_p(stability: 200, difficulty: 1), now);
      expect(s, lessThan(1.0));
    });

    test('lapses increase weakness', () {
      final low = termWeaknessScore(_p(lapses: 0), now);
      final high = termWeaknessScore(_p(lapses: 4), now);
      expect(high, greaterThan(low));
    });

    test('overdue increases weakness', () {
      final notDue = termWeaknessScore(
        _p(due: now.add(const Duration(days: 3))),
        now,
      );
      final overdue = termWeaknessScore(
        _p(due: now.subtract(const Duration(days: 6))),
        now,
      );
      expect(overdue, greaterThan(notDue));
    });

    test('relearning state adds weakness', () {
      final review = termWeaknessScore(_p(state: 2), now);
      final relearning = termWeaknessScore(_p(state: 3), now);
      expect(relearning, greaterThan(review));
    });
  });

  group('orderTermsByWeakness', () {
    test('ranks weakest first', () {
      final order = orderTermsByWeakness(
        terms: ['strong', 'weak', 'medium'],
        progressByTerm: {
          'strong': _p(stability: 300, difficulty: 1),
          'weak': _p(lapses: 5, difficulty: 9, state: 3),
          'medium': _p(lapses: 1, difficulty: 5),
        },
        now: now,
      );
      expect(order.first, 'weak');
      expect(order.last, 'strong');
    });

    test('terms without progress use the baseline and still rank', () {
      final order = orderTermsByWeakness(
        terms: ['tracked_strong', 'untracked', 'tracked_weak'],
        progressByTerm: {
          'tracked_strong': _p(stability: 300, difficulty: 1),
          'tracked_weak': _p(lapses: 6, difficulty: 9),
        },
        now: now,
      );
      // weak (failed) > untracked (1.5 baseline) > strong (<1.0)
      expect(order, ['tracked_weak', 'untracked', 'tracked_strong']);
    });

    test('is stable for equal scores (preserves input order)', () {
      final order = orderTermsByWeakness(
        terms: ['a', 'b', 'c'],
        progressByTerm: const {}, // all null → equal baseline
        now: now,
      );
      expect(order, ['a', 'b', 'c']);
    });
  });

  group('VocabularyTracker priorityOrder', () {
    test('selects from priority order first', () {
      final tracker = VocabularyTracker(
        allTerms: ['apple', 'banana', 'cherry', 'date'],
        allTermDefinitions: const {},
        maxTargetCount: 2,
        priorityOrder: ['cherry', 'date', 'apple', 'banana'],
      );
      expect(tracker.targetTerms, ['cherry', 'date']);
    });

    test('tops up from remaining terms when priority list is short', () {
      final tracker = VocabularyTracker(
        allTerms: ['apple', 'banana', 'cherry'],
        allTermDefinitions: const {},
        maxTargetCount: 3,
        priorityOrder: ['cherry'],
      );
      expect(tracker.targetTerms.first, 'cherry');
      expect(tracker.targetTerms.length, 3);
      expect(tracker.targetTerms.toSet(), {'apple', 'banana', 'cherry'});
    });

    test('dedups across priority and fallback', () {
      final tracker = VocabularyTracker(
        allTerms: ['apple', 'banana'],
        allTermDefinitions: const {},
        maxTargetCount: 5,
        priorityOrder: ['banana', 'banana', 'apple'],
      );
      expect(tracker.targetTerms, ['banana', 'apple']);
    });
  });
}
