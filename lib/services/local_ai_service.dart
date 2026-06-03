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

  // —— Output cleaners (visible for testing) ——

  /// Trim model output to the first non-empty sentence.
  /// Strips leading labels (e.g. "提示：", "口訣：") and quote marks.
  static String cleanSingleSentence(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return '';

    // Strip common Chinese labels the model may echo back
    for (final label in const ['提示：', '口訣：', 'Hint:', 'Mnemonic:']) {
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
