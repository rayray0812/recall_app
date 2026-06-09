import 'package:flutter/foundation.dart';
import 'package:recall_app/services/ai/local_llm_engine.dart';
import 'package:recall_app/services/ai_analytics_service.dart';
import 'package:recall_app/services/ai_error.dart';
import 'package:recall_app/services/ai_task.dart';

/// Local-AI assistant service for low-latency, single-sentence tasks.
///
/// Backed by a [LocalLlmEngine] (Android LiteRT-LM or Apple Foundation Models),
/// so it is agnostic to which on-device backend runs the inference.
/// Used for high-frequency UX moments where cloud latency is unacceptable:
/// - L1: review hints during SRS flip
/// - L2: mnemonic generation
/// - L3: confusion diagnosis after a wrong quiz answer
///
/// All methods return `null` when the model is unavailable or inference fails,
/// rather than throwing. This makes UI integration safe — caller can simply
/// hide the feature when null is returned.
class LocalAiService {
  LocalAiService._();

  static const int _hintMaxTokens = 96;
  static const int _mnemonicMaxTokens = 96;
  static const int _confusionMaxTokens = 160;
  static const int _exampleMaxTokens = 80;
  static const int _distractorMaxTokens = 160;

  /// L1: Generate a one-sentence hint that points toward [term] without
  /// revealing [definition] directly.
  ///
  /// Latency target: < 500ms on small local models (single short sentence).
  static Future<String?> generateReviewHint({
    required LocalLlmEngine engine,
    required String term,
    required String definition,
  }) async {
    return _runWithAnalytics(
      taskType: AiTaskType.reviewHint,
      engine: engine,
      operation: () async {
        final prompt = buildReviewHintPrompt(
          term: term,
          definition: definition,
        );
        final raw = await engine.generate(
          prompt: prompt,
          maxTokens: _hintMaxTokens,
          temperature: 0.3,
          topK: 40,
        );
        return cleanSingleSentence(raw);
      },
    );
  }

  /// L2: Generate a memory mnemonic for [term].
  ///
  /// Mnemonic styles include: 諧音 (homophone), 拆字 (decomposition),
  /// 聯想 (association), 短故事 (mini-story).
  static Future<String?> generateMnemonic({
    required LocalLlmEngine engine,
    required String term,
    required String definition,
  }) async {
    return _runWithAnalytics(
      taskType: AiTaskType.mnemonic,
      engine: engine,
      operation: () async {
        final prompt = buildMnemonicPrompt(term: term, definition: definition);
        final raw = await engine.generate(
          prompt: prompt,
          maxTokens: _mnemonicMaxTokens,
          temperature: 0.6,
          topK: 40,
        );
        return cleanSingleSentence(raw);
      },
    );
  }

  /// L3: Explain why [chosenTerm] and [targetTerm] are commonly confused, and
  /// suggest a memory hook to keep them apart.
  static Future<String?> generateConfusionExplanation({
    required LocalLlmEngine engine,
    required String targetTerm,
    required String targetDefinition,
    required String chosenTerm,
    required String chosenDefinition,
  }) async {
    return _runWithAnalytics(
      taskType: AiTaskType.confusionDiagnosis,
      engine: engine,
      operation: () async {
        final prompt = buildConfusionPrompt(
          targetTerm: targetTerm,
          targetDefinition: targetDefinition,
          chosenTerm: chosenTerm,
          chosenDefinition: chosenDefinition,
        );
        final raw = await engine.generate(
          prompt: prompt,
          maxTokens: _confusionMaxTokens,
          temperature: 0.3,
          topK: 40,
        );
        return cleanShortParagraph(raw);
      },
    );
  }

  /// Generate one natural example sentence that uses [term], suitable for a
  /// high-school learner. Used to fill a card's example-sentence field.
  static Future<String?> generateExampleSentence({
    required LocalLlmEngine engine,
    required String term,
    required String definition,
  }) async {
    return _runWithAnalytics(
      taskType: AiTaskType.exampleSentence,
      engine: engine,
      operation: () async {
        final prompt = buildExampleSentencePrompt(
          term: term,
          definition: definition,
        );
        final raw = await engine.generate(
          prompt: prompt,
          maxTokens: _exampleMaxTokens,
          temperature: 0.7,
          topK: 40,
        );
        final sentence = cleanSingleSentence(raw);
        return sentence.toLowerCase().contains(term.toLowerCase())
            ? sentence
            : '';
      },
    );
  }

  /// Generate up to [count] plausible-but-wrong multiple-choice options for a
  /// quiz question about [term].
  ///
  /// When [reversed] is false the question asks for the *definition* of [term],
  /// so distractors are wrong definitions; when true the question asks for the
  /// *term*, so distractors are similar-looking/meaning words. [correctOption]
  /// is the real answer (already POS-stripped) and is excluded from the result.
  ///
  /// Returns null when the model is unavailable, fails, or produces fewer than
  /// [count] usable distractors — callers should fall back to their baseline
  /// (random other-card) options in that case.
  static Future<List<String>?> generateDistractors({
    required LocalLlmEngine engine,
    required String term,
    required String definition,
    required String correctOption,
    required bool reversed,
    int count = 3,
  }) async {
    final task = AiTask(
      type: AiTaskType.smartDistractors,
      provider: engine.backend.name,
      startedAt: DateTime.now().toUtc(),
    );
    final analytics = AiAnalyticsService();
    try {
      final prompt = buildDistractorsPrompt(
        term: term,
        definition: definition,
        correctOption: correctOption,
        reversed: reversed,
        count: count,
      );
      final raw = await engine.generate(
        prompt: prompt,
        maxTokens: _distractorMaxTokens,
        temperature: 0.8,
        topK: 50,
      );
      final list =
          parseDistractorLines(raw, exclude: correctOption, max: count * 3)
              .where((d) => isDistractorShapeValid(d, reversed: reversed))
              .take(count)
              .toList();
      analytics.logEvent(
        taskType: task.type,
        provider: task.provider,
        success: true,
        elapsed: task.elapsed,
      );
      return list.length >= count ? list : null;
    } catch (e) {
      final reason = AiErrorClassifier.classifySdkError(e.toString());
      analytics.logEvent(
        taskType: task.type,
        provider: task.provider,
        success: false,
        elapsed: task.elapsed,
        failureReason: reason,
      );
      if (kDebugMode) {
        debugPrint('LocalAiService.generateDistractors failed: $e');
      }
      return null;
    }
  }

  // —— Prompt builders (visible for testing) ——

  static String buildReviewHintPrompt({
    required String term,
    required String definition,
  }) {
    return '''你是語言學習助教。為下面這個單字提供一個提示，幫學生回憶它的意思，但不要直接說出意思。

單字：$term
（意思僅供你參考，不要寫進提示）：$definition

要求：
- 一句話，不超過 25 字
- 可以提示情境、同類詞、搭配，但不可以直接寫出意思
- 不要使用 "意思是"、"代表" 這類字眼

提示：''';
  }

  static String buildMnemonicPrompt({
    required String term,
    required String definition,
  }) {
    return '''你是記憶口訣專家。為下面這個單字寫一個短小的記憶口訣。

單字：$term
意思：$definition

可用方法：諧音、拆字、聯想、短故事。
請只輸出口訣本身，不超過 30 字，不需要解釋：

口訣：''';
  }

  static String buildConfusionPrompt({
    required String targetTerm,
    required String targetDefinition,
    required String chosenTerm,
    required String chosenDefinition,
  }) {
    return '''你是語言學習助教。學生剛在測驗中把 "$targetTerm" 誤選為 "$chosenTerm"。請用兩句話：
1. 點出兩者最關鍵的差異
2. 給一個記憶區別的小技巧

正確：$targetTerm（$targetDefinition）
誤選：$chosenTerm（$chosenDefinition）

每句不超過 25 字，請直接回答：''';
  }

  static String buildExampleSentencePrompt({
    required String term,
    required String definition,
  }) {
    return '''/no_think
Word: "$term"
Meaning: "$definition"
Write one short natural English sentence using "$term". No Chinese, labels, translation, or explanation.''';
  }

  static String buildDistractorsPrompt({
    required String term,
    required String definition,
    required String correctOption,
    required bool reversed,
    int count = 3,
  }) {
    if (reversed) {
      // Question shows the definition, asks for the term → distractors are
      // look-alike words, not synonyms of the answer.
      return '''你是出題老師。學生要從選項中選出對應「$definition」的正確單字（正解是 "$correctOption"）。
請設計 $count 個「長得像、拼字相近、字根/字尾容易搞混，但意思不同」的英文單字當干擾選項。

要求：
- 每行一個單字，總共 $count 行
- 優先選拼字外觀相近、字首/字尾/音節相似的字
- 不要產生 "$correctOption" 的同義詞、近義詞或解釋
- 不可以是正解 "$correctOption" 本身，也不要重複
- 只輸出單字，不要編號、不要解釋

干擾選項：''';
    }
    // Question shows the term, asks for the definition → choose look-alike
    // English decoy words first, then output only their Chinese meanings.
    return '''你是台灣高中英文測驗出題老師。題目顯示英文單字 "$term"，學生要選正確的繁體中文意思。
正解：「$correctOption」
補充定義：$definition

請先想出 $count 個和 "$term" 長得像、拼字相近、字根/字尾容易搞混，但意思不同的英文錯字。
然後只輸出這些錯字對應的「繁體中文意思」作為干擾選項。

嚴格要求：
- 每行一個繁體中文意思，總共 $count 行
- 必須是中文釋義，不可以輸出英文單字、英文近義詞、例句或解釋
- 來源錯字要和 "$term" 外觀相似，不要只找意思相近的字
- 意思要明確錯誤，不能是「$correctOption」的同義改寫、上位詞、近義詞或通用解釋
- 避免太通用的答案，例如：好的、壞的、重要的、東西、事情
- 不要重複，不要編號，不要解釋

干擾選項：''';
  }

  // —— Output cleaners (visible for testing) ——

  /// Trim model output to the first non-empty sentence.
  /// Strips leading labels (e.g. "提示：", "口訣：") and quote marks.
  static String cleanSingleSentence(String raw) {
    var text = _stripReasoning(raw).trim();
    if (text.isEmpty) return '';

    // Strip common Chinese labels the model may echo back
    text = _stripLeadingLabels(text);

    // Take the first paragraph
    text = _firstUsefulLine(text);
    text = _stripLeadingLabels(text);

    // Strip surrounding quotes / markdown
    text = text.replaceAll(RegExp(r'^["「『]+|["」』]+$'), '');
    text = text.replaceAll(RegExp(r'^\*\*|\*\*$'), '').trim();
    if (text.toLowerCase() == 'think' || text.toLowerCase() == '/think') {
      return '';
    }

    return text;
  }

  static bool isLikelyEnglishSentence(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    if (RegExp(r'[\u3400-\u9fff]').hasMatch(trimmed)) return false;

    final latinChars = RegExp(r'[A-Za-z]').allMatches(trimmed).length;
    if (latinChars < 3) return false;

    final letters = RegExp(r'[A-Za-z\u3400-\u9fff]').allMatches(trimmed).length;
    if (letters == 0) return false;
    return latinChars / letters >= 0.85;
  }

  /// Trim model output to the first 1-2 sentences (for L3).
  static String cleanShortParagraph(String raw) {
    var text = _stripReasoning(raw).trim();
    if (text.isEmpty) return '';

    // Drop any leading "1." or "•" list bullets the model may insert
    text = text.replaceAll(RegExp(r'^\d+\.\s*', multiLine: true), '');
    text = text.replaceAll(RegExp(r'^[•·]\s*', multiLine: true), '');

    // Keep first 2 lines max
    final lines = text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .take(2)
        .toList();
    return lines.join('\n');
  }

  static String _stripReasoning(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return '';

    // Qwen3-style reasoning models may emit <think>...</think> before the
    // answer. Remove complete blocks first.
    text = text.replaceAll(
      RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
      '',
    );

    // If the runtime returns an unfinished <think> block, do not salvage lines
    // from it. Those lines are reasoning, not user-facing output.
    if (text.toLowerCase().contains('<think>')) {
      return '';
    }

    return text.trim();
  }

  static String _stripLeadingLabels(String text) {
    var out = text.trim();
    for (final label in const [
      '提示：',
      '口訣：',
      '例句：',
      '答案：',
      'Hint:',
      'Mnemonic:',
      'Example:',
      'Answer:',
    ]) {
      if (out.startsWith(label)) {
        out = out.substring(label.length).trim();
      }
    }
    return out;
  }

  static String _firstUsefulLine(String text) {
    for (final line in text.split('\n')) {
      final cleaned = _stripLeadingLabels(line).trim();
      if (cleaned.isEmpty) continue;
      if (cleaned.startsWith('<')) continue;
      if (cleaned.toLowerCase() == 'think') continue;
      return cleaned;
    }
    return '';
  }

  /// Parse a model's multi-line distractor output into clean option strings.
  ///
  /// Strips leading numbering (`1.`, `2)`, `3、`), bullets (`-`, `•`, `*`) and
  /// surrounding quotes; drops blanks, duplicates (case-insensitive), and any
  /// line equal to [exclude] (the correct answer). Caps the result at [max].
  static List<String> parseDistractorLines(
    String raw, {
    required String exclude,
    int max = 3,
  }) {
    final excludeNorm = exclude.trim().toLowerCase();
    final seen = <String>{};
    final out = <String>[];

    for (final line in raw.split('\n')) {
      var t = line.trim();
      if (t.isEmpty) continue;
      // Strip leading numbering / bullets the model may add.
      t = t.replaceFirst(RegExp(r'^\d+\s*[.)、:：]\s*'), '');
      t = t.replaceFirst(RegExp(r'^[-•·*]\s*'), '');
      // Strip a leading label like "干擾選項：" if echoed back.
      t = t.replaceFirst(RegExp(r'^干擾選項[:：]\s*'), '');
      // Strip surrounding quotes.
      t = t.replaceAll(RegExp(r'^["「『]+|["」』]+$'), '').trim();
      if (t.isEmpty) continue;

      final norm = t.toLowerCase();
      if (norm == excludeNorm) continue;
      if (seen.add(norm)) out.add(t);
      if (out.length >= max) break;
    }
    return out;
  }

  static bool isDistractorShapeValid(String value, {required bool reversed}) {
    final text = value.trim();
    if (text.isEmpty) return false;
    final hasCjk = RegExp(r'[\u3400-\u9fff]').hasMatch(text);
    final hasLatin = RegExp(r'[A-Za-z]').hasMatch(text);

    // term → definition: choices must be Chinese meanings, not English
    // synonyms. definition → term: choices must be English words/phrases.
    return reversed ? hasLatin && !hasCjk : hasCjk && !hasLatin;
  }

  // —— Internal: shared analytics + error handling wrapper ——

  static Future<String?> _runWithAnalytics({
    required AiTaskType taskType,
    required LocalLlmEngine engine,
    required Future<String> Function() operation,
  }) async {
    final task = AiTask(
      type: taskType,
      provider: engine.backend.name,
      startedAt: DateTime.now().toUtc(),
    );
    final analytics = AiAnalyticsService();
    try {
      final result = await operation();
      analytics.logEvent(
        taskType: task.type,
        provider: task.provider,
        success: true,
        elapsed: task.elapsed,
      );
      return result.isEmpty ? null : result;
    } catch (e) {
      final reason = AiErrorClassifier.classifySdkError(e.toString());
      analytics.logEvent(
        taskType: task.type,
        provider: task.provider,
        success: false,
        elapsed: task.elapsed,
        failureReason: reason,
      );
      debugPrint('LocalAiService failed: $e');
      return null;
    }
  }
}
