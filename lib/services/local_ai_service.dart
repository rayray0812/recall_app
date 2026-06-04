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
        return cleanSingleSentence(raw);
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
      final list = parseDistractorLines(raw, exclude: correctOption, max: count);
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
      debugPrint('LocalAiService.generateDistractors failed: $e');
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
    return '''你是英語學習助教。用單字 "$term" 造一個自然、簡單的例句，適合高中生理解。

單字：$term
意思：$definition

要求：
- 只輸出一句例句，句子裡必須包含 "$term"
- 句子簡短、口語、貼近生活
- 不要附中文翻譯，也不要解釋

例句：''';
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
      // other plausible words (similar spelling or meaning), not the answer.
      return '''你是出題老師。學生要從選項中選出對應「$definition」的正確單字（正解是 "$correctOption"）。
請設計 $count 個「看起來很像、但其實錯誤」的單字當干擾選項。

要求：
- 每行一個單字，總共 $count 行
- 與 "$correctOption" 同類型、長度相近，容易混淆（例如拼字相近或意思相關）
- 不可以是正解 "$correctOption" 本身，也不要重複
- 只輸出單字，不要編號、不要解釋

干擾選項：''';
    }
    // Question shows the term, asks for the definition → distractors are wrong
    // definitions that look reasonable for this kind of word.
    return '''你是出題老師。學生要從選項中選出單字 "$term" 的正確中文意思（正解是「$correctOption」）。
請設計 $count 個「看起來合理、但其實錯誤」的中文意思當干擾選項。

要求：
- 每行一個意思，總共 $count 行
- 風格、長度與「$correctOption」相近，似是而非、容易誤選
- 不可以等於正解「$correctOption」，也不要重複
- 只輸出意思本身，不要編號、不要解釋

干擾選項：''';
  }

  // —— Output cleaners (visible for testing) ——

  /// Trim model output to the first non-empty sentence.
  /// Strips leading labels (e.g. "提示：", "口訣：") and quote marks.
  static String cleanSingleSentence(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return '';

    // Strip common Chinese labels the model may echo back
    for (final label in const [
      '提示：',
      '口訣：',
      '例句：',
      'Hint:',
      'Mnemonic:',
      'Example:',
    ]) {
      if (text.startsWith(label)) {
        text = text.substring(label.length).trim();
      }
    }

    // Take the first paragraph
    final firstBreak = text.indexOf('\n');
    if (firstBreak != -1) {
      text = text.substring(0, firstBreak).trim();
    }

    // Strip surrounding quotes / markdown
    text = text.replaceAll(RegExp(r'^["「『]+|["」』]+$'), '');
    text = text.replaceAll(RegExp(r'^\*\*|\*\*$'), '').trim();

    return text;
  }

  /// Trim model output to the first 1-2 sentences (for L3).
  static String cleanShortParagraph(String raw) {
    var text = raw.trim();
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
