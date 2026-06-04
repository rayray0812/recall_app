import 'package:recall_app/models/card_progress.dart';

/// Heuristics for focusing conversation practice on a learner's FSRS weak
/// points. Pure Dart — no Flutter/Riverpod — so it is fully unit-testable.

/// A weakness score for one term's [CardProgress]; higher = weaker = more worth
/// drilling. Combines the FSRS signals that indicate fragile memory:
/// overdue-ness, difficulty, past lapses, relearning state, and low stability.
///
/// A null progress (never tracked) gets a mild positive baseline so brand-new
/// words still surface, but rank below cards the learner has actually failed.
double termWeaknessScore(CardProgress? p, DateTime now) {
  if (p == null) return 1.5;
  var score = 0.0;
  if (p.due != null && p.due!.isBefore(now)) {
    final daysOverdue = now.difference(p.due!).inDays.clamp(0, 14);
    score += 1.0 + daysOverdue * 0.3;
  }
  score += p.difficulty * 0.5; // FSRS difficulty (~1..10)
  score += p.lapses * 1.0; // each past failure
  if (p.state == 3) score += 1.0; // relearning
  if (p.stability > 0 && p.stability < 7) {
    score += (7 - p.stability) / 7; // fragile memory
  }
  return score;
}

/// Reorders [terms] weakest-first using [termWeaknessScore].
///
/// Stable: terms with equal scores keep their original relative order, so the
/// result is deterministic (important for predictable tests and a calm UX).
/// Terms absent from [progressByTerm] are scored as null (mild baseline).
List<String> orderTermsByWeakness({
  required List<String> terms,
  required Map<String, CardProgress> progressByTerm,
  required DateTime now,
}) {
  final indexed = terms.asMap().entries.toList();
  indexed.sort((a, b) {
    final sa = termWeaknessScore(progressByTerm[a.value], now);
    final sb = termWeaknessScore(progressByTerm[b.value], now);
    final cmp = sb.compareTo(sa); // descending: weakest first
    return cmp != 0 ? cmp : a.key.compareTo(b.key); // stable tie-break
  });
  return indexed.map((e) => e.value).toList();
}
