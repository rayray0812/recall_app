import 'dart:convert';

import 'package:recall_app/services/ai/local_llm_engine.dart';

/// One auto-filled vocabulary card: a Traditional-Chinese definition, an
/// optional part-of-speech tag, and an optional English example sentence.
class CardLookupResult {
  const CardLookupResult({
    required this.definition,
    this.pos = '',
    this.example = '',
  });

  /// Traditional-Chinese meaning (the field that makes the result usable).
  final String definition;

  /// Part of speech, e.g. `n.` / `v.` / `adj.` Empty when unknown.
  final String pos;

  /// One short English example sentence. Empty when unavailable.
  final String example;

  /// Quality gate: a result is only usable when it carries a real
  /// Chinese definition. Tiny on-device models often emit English-only or
  /// malformed output — those fail this check so the caller can escalate to
  /// the cloud proxy (per the "本地效果不好就用遠端" requirement).
  bool get isUsable => _hasCjk(definition);

  static bool _hasCjk(String text) {
    for (final rune in text.runes) {
      if (rune >= 0x4E00 && rune <= 0x9FFF) return true;
    }
    return false;
  }
}

/// Builds prompts and parses model output for AI card auto-fill
/// ([AiTaskType.cardLookup]). Pure + static so it is unit-testable without a
/// device, network, or Hive.
class CardLookupService {
  const CardLookupService._();

  /// Cap kept small: the expected output is a single compact JSON object.
  static const int maxTokens = 220;

  /// System instruction shared by the local and cloud paths.
  static const String systemPrompt =
      'You are a bilingual English → Traditional Chinese dictionary for '
      'Taiwanese high-school students. Reply with ONLY one compact JSON object. '
      'No markdown, no code fences, no commentary.';

  static String buildPrompt(String term) {
    final t = term.trim();
    return 'For the English word "$t" output exactly this JSON shape:\n'
        '{"definition":"<concise Traditional Chinese meaning>",'
        '"pos":"<part of speech: n./v./adj./adv./prep./conj./pron.>",'
        '"example":"<one short natural English sentence that uses \\"$t\\">"}';
  }

  /// Lenient parse of model output. Tolerates code fences and surrounding
  /// prose by extracting the first `{ … }` block, then falls back to per-field
  /// regex when the JSON itself is malformed. Returns null when nothing usable
  /// can be extracted.
  static CardLookupResult? parse(String raw, {String? term}) {
    if (raw.trim().isEmpty) return null;

    final jsonResult = _tryJson(raw);
    if (jsonResult != null) return jsonResult;

    // Fallback: pull individual fields out of loosely-formatted text.
    final definition = _field(raw, 'definition');
    if (definition == null || definition.isEmpty) return null;
    return CardLookupResult(
      definition: definition,
      pos: _normalizePos(_field(raw, 'pos') ?? ''),
      example: _field(raw, 'example') ?? '',
    );
  }

  static CardLookupResult? _tryJson(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final decoded = jsonDecode(raw.substring(start, end + 1));
      if (decoded is! Map) return null;
      final definition = _string(decoded['definition']);
      if (definition.isEmpty) return null;
      return CardLookupResult(
        definition: definition,
        pos: _normalizePos(_string(decoded['pos'])),
        example: _string(decoded['example']),
      );
    } catch (_) {
      return null;
    }
  }

  static String _string(Object? value) => value is String ? value.trim() : '';

  static String? _field(String raw, String key) {
    final match = RegExp(
      '"?$key"?\\s*[:：]\\s*"?([^"\\n}]+)',
      caseSensitive: false,
    ).firstMatch(raw);
    return match?.group(1)?.trim();
  }

  /// Normalize a part-of-speech tag to a short canonical form, dropping noise.
  static String _normalizePos(String raw) {
    final lower = raw.toLowerCase().trim();
    if (lower.isEmpty) return '';
    const map = {
      'noun': 'n.',
      'verb': 'v.',
      'adjective': 'adj.',
      'adverb': 'adv.',
      'preposition': 'prep.',
      'conjunction': 'conj.',
      'pronoun': 'pron.',
    };
    for (final entry in map.entries) {
      if (lower.startsWith(entry.key)) return entry.value;
    }
    // Already-abbreviated forms: keep only the short token (e.g. "n." / "v.").
    final m = RegExp(r'^(n|v|adj|adv|prep|conj|pron)\.?').firstMatch(lower);
    if (m != null) return '${m.group(1)}.';
    return '';
  }

  /// Run card auto-fill on the on-device model. Returns null (→ caller escalates
  /// to the cloud proxy) when the model is unavailable, errors, or produces a
  /// result that fails [CardLookupResult.isUsable].
  static Future<CardLookupResult?> generateLocal({
    required LocalLlmEngine engine,
    required String term,
  }) async {
    try {
      final raw = await engine.generate(
        prompt: '$systemPrompt\n\n${buildPrompt(term)}',
        maxTokens: maxTokens,
        temperature: 0.3,
        topK: 40,
      );
      final result = parse(raw, term: term);
      return (result != null && result.isUsable) ? result : null;
    } catch (_) {
      return null;
    }
  }
}
