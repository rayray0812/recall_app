import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:recall_app/services/gemini_service.dart';
import 'package:recall_app/services/ocr_parser_service.dart';
import 'package:recall_app/services/ocr_service.dart';

/// Status of a local model file.
@immutable
class LocalModelStatus {
  const LocalModelStatus({
    required this.ready,
    required this.message,
    this.sizeMb = 0,
  });

  final bool ready;
  final String message;
  final int sizeMb;

  factory LocalModelStatus.fromMap(Map<dynamic, dynamic> map) {
    return LocalModelStatus(
      ready: map['ready'] == true,
      message: (map['message'] as String?) ?? '',
      sizeMb: (map['sizeMb'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Bridge to Android LiteRT-LM via MethodChannel.
///
/// Optimized for small on-device models (Gemma/Qwen LiteRT-LM files):
/// - Simple, few-shot prompts instead of complex instructions
/// - Robust parser that recovers from malformed JSON
/// - OCR text-only input (no spatial coordinates for simple cases)
class OnDeviceAiService {
  OnDeviceAiService._();

  static const MethodChannel _channel = MethodChannel(
    'recall_app/on_device_ai',
  );

  /// Check if a model file exists and is usable.
  static Future<LocalModelStatus> checkModel(String modelPath) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'checkModel',
        {'modelPath': modelPath},
      );
      if (raw == null) {
        return const LocalModelStatus(
          ready: false,
          message: 'No response from platform.',
        );
      }
      return LocalModelStatus.fromMap(raw);
    } on MissingPluginException {
      return const LocalModelStatus(
        ready: false,
        message: 'On-device AI is only available on Android.',
      );
    } catch (e) {
      return LocalModelStatus(ready: false, message: 'Check failed: $e');
    }
  }

  /// Run inference with the local model. Returns raw text output.
  ///
  /// [temperature] defaults to 0.0 (greedy / deterministic) — best for
  /// structured JSON output. Raise only when creative responses are needed.
  /// [topK] defaults to 1 (greedy). Combined with temperature=0 this gives
  /// fully deterministic, format-following output.
  static Future<String> runInference({
    required String modelPath,
    required String prompt,
    int maxTokens = 4096,
    double temperature = 0.0,
    int topK = 1,
  }) async {
    final result = await _channel.invokeMethod<String>('runInference', {
      'modelPath': modelPath,
      'prompt': prompt,
      'maxTokens': maxTokens,
      'temperature': temperature,
      'topK': topK,
    });
    return result ?? '';
  }

  /// Unload cached model to free memory.
  static Future<void> unloadModel() async {
    try {
      await _channel.invokeMethod<String>('unloadModel');
    } catch (e) {
      debugPrint('unloadModel failed: $e');
    }
  }

  /// High-level: extract flashcards from OCR result using local model.
  static Future<List<Map<String, String>>> extractFlashcards({
    required String modelPath,
    required OcrResult ocrResult,
  }) async {
    if (modelPath.trim().isEmpty) {
      throw ScanException(
        ScanFailureReason.invalidRequest,
        'No local model file configured. Import a .litertlm model in Settings.',
      );
    }
    if (!ocrResult.hasEnoughText) {
      throw ScanException(
        ScanFailureReason.invalidRequest,
        'Not enough text recognized from the image.',
      );
    }

    final status = await checkModel(modelPath);
    if (!status.ready) {
      throw ScanException(ScanFailureReason.invalidRequest, status.message);
    }

    final prompt = _buildStructuredPrompt(ocrResult);

    if (kDebugMode) {
      debugPrint('Gemma prompt (${prompt.length} chars):\n$prompt');
    }

    final raw = await runInference(
      modelPath: modelPath,
      prompt: prompt,
      maxTokens: 4096,
    );

    final trimmed = raw.trim();
    if (kDebugMode) {
      debugPrint('Gemma raw output (${trimmed.length} chars):\n$trimmed');
    }

    if (trimmed.isEmpty) {
      throw ScanException(
        ScanFailureReason.invalidRequest,
        'Local model returned an empty response.',
      );
    }

    final results = parseLocalModelResponse(trimmed);
    if (results.isEmpty) {
      throw ScanException(
        ScanFailureReason.parseError,
        'Could not parse flashcards from local model output.',
      );
    }
    return results;
  }

  /// Extract flashcards for textbook mode (key concepts).
  static Future<List<Map<String, String>>> extractTextbookFlashcards({
    required String modelPath,
    required OcrResult ocrResult,
  }) async {
    if (modelPath.trim().isEmpty) {
      throw ScanException(
        ScanFailureReason.invalidRequest,
        'No local model file configured.',
      );
    }
    if (!ocrResult.hasEnoughText) {
      throw ScanException(
        ScanFailureReason.invalidRequest,
        'Not enough text recognized from the image.',
      );
    }

    final status = await checkModel(modelPath);
    if (!status.ready) {
      throw ScanException(ScanFailureReason.invalidRequest, status.message);
    }

    final prompt = _buildTextbookPrompt(ocrResult);

    if (kDebugMode) {
      debugPrint('Gemma textbook prompt (${prompt.length} chars):\n$prompt');
    }

    final raw = await runInference(
      modelPath: modelPath,
      prompt: prompt,
      maxTokens: 1536,
    );

    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw ScanException(
        ScanFailureReason.invalidRequest,
        'Local model returned an empty response.',
      );
    }

    final results = parseLocalModelResponse(trimmed);
    if (results.isEmpty) {
      throw ScanException(
        ScanFailureReason.parseError,
        'Could not parse flashcards from local model output.',
      );
    }
    return results;
  }

  /// Build a spatially pre-paired prompt to eliminate meaning drift.
  ///
  /// Strategy 1: Two-column layout confirmed by spatial analysis →
  ///   format as "TERM | DEFINITION" rows so the model only cleans, never pairs.
  /// Strategy 2 (fallback): pass to [_buildPrompt] which now includes both
  ///   same-line and alternating-line examples.
  static String _buildStructuredPrompt(OcrResult ocrResult) {
    final layout = OcrParserService.analyzeLayout(ocrResult);
    final dividerX = layout.dividerX;
    final rows = layout.rows;

    // --- Strategy 1: confirmed two-column layout ---
    if (dividerX != null && rows.isNotEmpty) {
      final pairLines = <String>[];
      for (final row in rows) {
        final left = row
            .where((l) => l.centerX < dividerX)
            .map((l) => l.text.trim())
            .where((t) => t.isNotEmpty)
            .join(' ')
            .trim();
        final right = row
            .where((l) => l.centerX >= dividerX)
            .map((l) => l.text.trim())
            .where((t) => t.isNotEmpty)
            .join(' ')
            .trim();
        if (left.isNotEmpty && right.isNotEmpty) {
          pairLines.add('$left | $right');
        }
        if (pairLines.length >= 40) break;
      }

      if (pairLines.length >= 2) {
        return '''
Clean these vocabulary pairs into JSON. Left of "|" = term. Right of "|" = definition.

Example:
apple | 蘋果
banana | 香蕉
[{"term":"apple","definition":"蘋果"},{"term":"banana","definition":"香蕉"}]

Rules:
- Keep LEFT as term and RIGHT as definition. Do NOT swap them.
- Skip header or page-number lines.
- Keep original language. Do not translate.
- Return ONLY the JSON array.

Input:
${pairLines.join('\n')}

Output:
[''';
      }
    }

    // --- Strategy 2: fall back to improved general prompt ---
    return _buildPrompt(ocrResult);
  }

  /// Build a simple, few-shot prompt optimized for small models.
  ///
  /// Key optimizations vs the old prompt:
  /// - No bounding-box coordinates (small models can't reason spatially)
  /// - Plain text input grouped by detected rows
  /// - 2 concrete few-shot examples so the model sees the exact format
  /// - Minimal instructions (small models get confused by long rules)
  /// - Explicit "do not add anything else" to reduce hallucination
  static String _buildPrompt(OcrResult ocrResult) {
    // Filter noise lines (page numbers, section headers, etc.) before sending
    // to the model — cleaner input reduces hallucination and wrong pairings.
    final textLines = ocrResult.lines
        .take(50)
        .map((line) => line.text.trim())
        .where(OcrParserService.isValidVocabLine)
        .toList();

    final ocrText = textLines.join('\n');

    return '''
Turn this vocabulary list into JSON flashcards.

Example (word and meaning on same line):
apple 蘋果
banana 香蕉
Output: [{"term":"apple","definition":"蘋果"},{"term":"banana","definition":"香蕉"}]

Example (word on one line, meaning on the next line):
abandon
放棄；拋棄
abroad
在國外
Output: [{"term":"abandon","definition":"放棄；拋棄"},{"term":"abroad","definition":"在國外"}]

Rules:
- If word and meaning are on the SAME line: split them into term/definition.
- If they ALTERNATE lines: pair each word with the line immediately after it.
- NEVER skip a line or mix up which meaning belongs to which word.
- Skip headers, page numbers, section titles.
- Keep original language. Do not translate or add content.
- Return ONLY the JSON array.

Input:
$ocrText

Output:
[''';
  }

  /// Build textbook-mode prompt for key concept extraction.
  static String _buildTextbookPrompt(OcrResult ocrResult) {
    final textLines = ocrResult.lines
        .take(40)
        .map((line) => line.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();

    final ocrText = textLines.join('\n');

    return '''
Read this textbook text and create flashcard Q&A pairs for studying.

Example input:
Photosynthesis is the process by which plants convert sunlight into energy.
The mitochondria is the powerhouse of the cell.

Example output:
[{"term":"What is photosynthesis?","definition":"The process by which plants convert sunlight into energy."},{"term":"What is the mitochondria?","definition":"The powerhouse of the cell."}]

Rules:
- Create 5-15 concise Q&A pairs from key concepts.
- Each item: {"term":"...","definition":"..."}
- Keep original language.
- Return ONLY the JSON array.

Input:
$ocrText

Output:
[''';
  }

  /// Parse raw output from a small local model.
  ///
  /// Small local models often produce:
  /// - Truncated JSON (missing closing brackets)
  /// - Extra text before/after the JSON
  /// - Missing quotes or trailing commas
  /// - Repeated explanations mixed in
  ///
  /// This parser tries multiple strategies:
  /// 1. Standard JSON parse (via GeminiService.parseResponse)
  /// 2. Repair common JSON issues and retry
  /// 3. Line-by-line regex extraction as last resort
  @visibleForTesting
  static List<Map<String, String>> parseLocalModelResponse(String raw) {
    var text = raw.trim();

    // The prompt ends with "Output:\n[" so the model continues from "[".
    // Prepend "[" if the output doesn't start with it.
    if (!text.startsWith('[') && !text.startsWith('{')) {
      text = '[$text';
    }

    // Strategy 1: Try standard parse first.
    try {
      final results = GeminiService.parseResponse(text);
      if (results.isNotEmpty) return results;
    } catch (_) {
      // Continue to repair strategies.
    }

    // Strategy 2: Repair common issues and retry.
    final repaired = _repairJson(text);
    if (repaired != null) {
      try {
        final results = GeminiService.parseResponse(repaired);
        if (results.isNotEmpty) return results;
      } catch (_) {
        // Continue to regex fallback.
      }
    }

    // Strategy 3: Extract individual JSON objects via regex.
    final regexResults = _extractByRegex(text);
    if (regexResults.isNotEmpty) return regexResults;

    // Strategy 4: Try to parse line-based "term: definition" patterns.
    return _extractByLinePatterns(text);
  }

  /// Try to repair broken JSON from small models.
  static String? _repairJson(String text) {
    var json = text;

    // Remove any text after the last } or ]
    final lastBrace = json.lastIndexOf('}');
    final lastBracket = json.lastIndexOf(']');
    final lastEnd = lastBrace > lastBracket ? lastBrace : lastBracket;
    if (lastEnd > 0) {
      json = json.substring(0, lastEnd + 1);
    }

    // Ensure it starts with [
    final firstBracket = json.indexOf('[');
    if (firstBracket >= 0) {
      json = json.substring(firstBracket);
    } else {
      final firstBrace = json.indexOf('{');
      if (firstBrace >= 0) {
        json = '[${json.substring(firstBrace)}';
      } else {
        return null;
      }
    }

    // Fix trailing commas before ] or }
    json = json.replaceAll(RegExp(r',\s*\]'), ']');
    json = json.replaceAll(RegExp(r',\s*\}'), '}');

    // Close unclosed array
    if (!json.trimRight().endsWith(']')) {
      // Check if last object is complete
      if (json.trimRight().endsWith('}')) {
        json = '${json.trimRight()}]';
      } else {
        // Try to close the last object and array
        final openBraces = '{'.allMatches(json).length;
        final closeBraces = '}'.allMatches(json).length;
        if (openBraces > closeBraces) {
          json = '$json${'}' * (openBraces - closeBraces)}]';
        } else {
          json = '$json]';
        }
      }
    }

    return json;
  }

  /// Extract term-definition pairs using regex patterns on individual objects.
  static List<Map<String, String>> _extractByRegex(String text) {
    final results = <Map<String, String>>[];

    // Match individual JSON-like objects: {"term":"...","definition":"..."}
    final objectPattern = RegExp(
      r'\{\s*"term"\s*:\s*"([^"]*?)"\s*,\s*"definition"\s*:\s*"([^"]*?)"[^}]*\}',
      caseSensitive: false,
    );

    for (final match in objectPattern.allMatches(text)) {
      final term = match.group(1)?.trim() ?? '';
      final definition = match.group(2)?.trim() ?? '';
      if (term.isNotEmpty && definition.isNotEmpty && term != definition) {
        results.add({'term': term, 'definition': definition});
      }
    }

    // Also try reverse order: {"definition":"...","term":"..."}
    if (results.isEmpty) {
      final reversePattern = RegExp(
        r'\{\s*"definition"\s*:\s*"([^"]*?)"\s*,\s*"term"\s*:\s*"([^"]*?)"[^}]*\}',
        caseSensitive: false,
      );
      for (final match in reversePattern.allMatches(text)) {
        final definition = match.group(1)?.trim() ?? '';
        final term = match.group(2)?.trim() ?? '';
        if (term.isNotEmpty && definition.isNotEmpty && term != definition) {
          results.add({'term': term, 'definition': definition});
        }
      }
    }

    return results;
  }

  /// Last-resort: try to find "word - meaning" or "word: meaning" patterns.
  static List<Map<String, String>> _extractByLinePatterns(String text) {
    final results = <Map<String, String>>[];
    final lines = text.split('\n');

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty ||
          trimmed.startsWith('[') ||
          trimmed.startsWith('{')) {
        continue;
      }

      // Try "term - definition" or "term: definition" or "term = definition"
      for (final sep in [' - ', ': ', ' = ', '\t', '   ']) {
        final idx = trimmed.indexOf(sep);
        if (idx > 0 && idx < trimmed.length - sep.length) {
          final term = trimmed.substring(0, idx).trim();
          final definition = trimmed.substring(idx + sep.length).trim();
          if (term.isNotEmpty &&
              definition.isNotEmpty &&
              term.length <= 80 &&
              definition.length <= 200 &&
              term != definition) {
            results.add({'term': term, 'definition': definition});
            break;
          }
        }
      }
    }

    return results;
  }
}
