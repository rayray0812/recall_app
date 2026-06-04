/// Tracks vocabulary coverage during a conversation practice session.
///
/// Pure Dart class — session-scoped, instantiated by the notifier.
/// Independently testable without Flutter/Riverpod.
class VocabularyTracker {
  static final RegExp _latinOrDigit = RegExp(r'[a-z0-9]');
  static final RegExp _nonWordChars = RegExp(
    r'[^a-z0-9\u4e00-\u9fff\u3400-\u4dbf\u3040-\u30ff\s]',
  );

  final List<String> targetTerms;
  final Map<String, String> termDefinitions;
  final Set<String> practicedTerms = {};
  int focusCursor = 0;

  /// [priorityOrder], when given, is a pre-ranked list of terms (e.g. FSRS
  /// weakest-first) that drives selection: target terms are taken from this
  /// order before falling back to the rest of [allTerms]. When null, selection
  /// is random (original behaviour) for variety across sessions.
  VocabularyTracker({
    required List<String> allTerms,
    required Map<String, String> allTermDefinitions,
    required int maxTargetCount,
    List<String>? priorityOrder,
  })  : targetTerms = _selectTerms(allTerms, maxTargetCount, priorityOrder),
        termDefinitions = {} {
    for (final t in targetTerms) {
      termDefinitions[t] = allTermDefinitions[t] ?? '';
    }
  }

  /// Create a tracker with pre-set target terms (for testing).
  VocabularyTracker.withTerms({
    required this.targetTerms,
    required this.termDefinitions,
  });

  static List<String> _selectTerms(
    List<String> terms,
    int maxCount,
    List<String>? priorityOrder,
  ) {
    // Priority path: take ranked terms first, then top up from the rest
    // (shuffled) so weak words are always covered without losing all variety.
    final ordered = priorityOrder == null
        ? (List<String>.from(terms)..shuffle())
        : <String>[
            ...priorityOrder,
            ...(List<String>.from(terms)..shuffle()),
          ];

    final deduped = <String>[];
    final seen = <String>{};
    for (final term in ordered) {
      if (deduped.length >= maxCount) break;
      final normalized = normalizeForMatch(term);
      if (normalized.isEmpty || seen.contains(normalized)) continue;
      seen.add(normalized);
      deduped.add(term);
    }
    return deduped;
  }

  /// Extract which target terms appear in the user's text.
  Set<String> extractUsedTerms(String text) {
    final normalizedText = normalizeForMatch(text);
    if (normalizedText.isEmpty || targetTerms.isEmpty) return {};
    final hits = <String>{};
    for (final term in targetTerms) {
      final normalizedTerm = normalizeForMatch(term);
      if (normalizedTerm.isEmpty) continue;
      if (_looksLatin(normalizedTerm)) {
        if (' $normalizedText '.contains(' $normalizedTerm ')) {
          hits.add(term);
        }
      } else if (normalizedText.contains(normalizedTerm)) {
        hits.add(term);
      }
    }
    return hits;
  }

  /// Get the next priority terms to focus on, starting from focusCursor.
  List<String> nextPriorityTerms({int? count, int? startOffset}) {
    final targetCount = count ?? 2;
    if (targetTerms.isEmpty) return [];
    final result = <String>[];
    var idx = startOffset ?? focusCursor;
    var guard = 0;
    while (result.length < targetCount && guard < targetTerms.length * 2) {
      final term = targetTerms[idx % targetTerms.length];
      if (!result.contains(term)) {
        result.add(term);
      }
      idx++;
      guard++;
    }
    return result;
  }

  /// Advance the focus cursor by [by] positions.
  void advanceFocusCursor(int by) {
    if (targetTerms.isEmpty) return;
    focusCursor = (focusCursor + by) % targetTerms.length;
  }

  /// How many terms to focus on per turn based on difficulty.
  static int targetTermsPerTurn(String difficulty) {
    switch (difficulty.toLowerCase().trim()) {
      case 'easy':
        return 1;
      case 'hard':
        return 3;
      default:
        return 2;
    }
  }

  /// Normalize text for matching (lowercase, strip punctuation).
  static String normalizeForMatch(String input) {
    final lower = input.toLowerCase().trim();
    if (lower.isEmpty) return '';
    return lower
        .replaceAll(_nonWordChars, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static bool _looksLatin(String value) => _latinOrDigit.hasMatch(value);
}
