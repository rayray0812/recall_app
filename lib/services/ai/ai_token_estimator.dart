/// Rough, dependency-free token estimator for mixed English / CJK text.
///
/// Used only for *cost telemetry* (ai_usage_events) and session budgeting — it
/// is deliberately an approximation, not a real tokenizer. The split matters
/// because CJK text packs far more tokens per character than English: most BPE
/// tokenizers emit roughly one token per CJK character but only ~1 token per 4
/// Latin characters. Counting them separately keeps the estimate honest for the
/// app's Chinese-heavy study content instead of wildly under-counting.
abstract final class AiTokenEstimator {
  /// Estimated token count for [text]. Empty → 0.
  static int estimate(String text) {
    if (text.isEmpty) return 0;
    var cjk = 0;
    var other = 0;
    for (final rune in text.runes) {
      if (_isCjk(rune)) {
        cjk++;
      } else {
        other++;
      }
    }
    // ~1 token per CJK char; ~1 token per 4 other chars.
    return cjk + (other / 4).ceil();
  }

  /// Sum of [estimate] over several parts (e.g. system prompt + user message).
  static int estimateAll(Iterable<String> parts) =>
      parts.fold(0, (sum, p) => sum + estimate(p));

  static bool _isCjk(int r) =>
      (r >= 0x4E00 && r <= 0x9FFF) || // CJK Unified Ideographs
      (r >= 0x3400 && r <= 0x4DBF) || // Extension A
      (r >= 0xF900 && r <= 0xFAFF) || // Compatibility Ideographs
      (r >= 0x3000 && r <= 0x303F) || // CJK symbols & punctuation
      (r >= 0x3040 && r <= 0x30FF) || // Hiragana + Katakana
      (r >= 0xFF00 && r <= 0xFFEF); // Fullwidth forms
}
