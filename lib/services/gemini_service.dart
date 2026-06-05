import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:recall_app/services/ai_error.dart';

export 'package:recall_app/services/ai_error.dart'
    show ScanFailureReason, ScanException;

enum PhotoScanMode { vocabularyList, textbookPage }

class ConversationScenario {
  final String? id;
  final String title;
  final String titleZh;
  final String setting;
  final String settingZh;
  final String aiRole;
  final String aiRoleZh;
  final String userRole;
  final String userRoleZh;
  final List<String> stages;
  final List<String> stagesZh;

  const ConversationScenario({
    this.id,
    required this.title,
    required this.titleZh,
    required this.setting,
    required this.settingZh,
    required this.aiRole,
    required this.aiRoleZh,
    required this.userRole,
    required this.userRoleZh,
    required this.stages,
    required this.stagesZh,
  });
}

class ConversationReplySuggestion {
  final String reply;
  final String zhHint;
  final String focusWord;

  const ConversationReplySuggestion({
    required this.reply,
    required this.zhHint,
    required this.focusWord,
  });
}

class GeminiService {
  static const _models = ['gemini-2.0-flash-lite', 'gemini-2.0-flash'];
  static const _timeout = Duration(seconds: 30);
  static const maxCards = 300;
  static const _lightweightModels = ['gemini-2.0-flash-lite'];

  static const _vocabularyPrompt =
      'Extract all term-definition pairs from this vocabulary list/word table image. '
      'Keep original language. For bilingual content, use one language as term and the other as definition. '
      'Skip headers, page numbers, section titles, numbering-only rows, and decorative text. '
      'Do NOT output items where term and definition are the same text. '
      'Do NOT guess when text is unreadable; skip uncertain rows. '
      'Preserve row pairing strictly (same row left/right). '
      'Also include an example sentence for each term in the same language when possible. '
      'If no clear sentence is available, return empty string for exampleSentence.';

  static const _textbookPrompt =
      'Extract 5-15 key concepts from this textbook/study material image as flashcard pairs. '
      'Create concise term (question/concept) and definition (answer/explanation). '
      'Keep original language. Focus on testable knowledge points. '
      'Skip page titles, headers/footers, page numbers, labels, and standalone fragments. '
      'Do NOT output duplicate concepts or same-text term/definition pairs. '
      'If uncertain, skip the item instead of guessing. '
      'Also provide an example sentence in the same language when possible; otherwise use empty string.';

  static const _jsonOnlySuffix =
      'Return ONLY valid JSON array. Do not use markdown fences. '
      'Each item must be: {"term":"...","definition":"...","exampleSentence":"..."} '
      'Exclude duplicates and invalid/noisy rows.';
  static const _vocabularyTextPrompt =
      'The following text was extracted by OCR from a vocabulary list image. '
      'Structure it into term-definition pairs. '
      'Keep original language. For bilingual content, use one language as term and the other as definition. '
      'Skip headers, page numbers, section titles, numbering-only rows, and decorative text. '
      'Do NOT output items where term and definition are the same text. '
      'Preserve row pairing as much as possible based on OCR order. '
      'Do not invent missing rows. '
      'exampleSentence should usually be empty unless a sentence is clearly present.';

  static const _textbookTextPrompt =
      'The following text was extracted by OCR from a textbook page. '
      'Extract 5-15 key concepts as flashcard pairs. '
      'Create concise term and definition pairs in the original language. '
      'Skip headers, footers, labels, and standalone fragments. '
      'Do not invent details. '
      'exampleSentence should be empty unless explicitly present.';

  static final _responseSchema = Schema.array(
    items: Schema.object(
      properties: {
        'term': Schema.string(description: 'The term or question'),
        'definition': Schema.string(description: 'The definition or answer'),
        'exampleSentence': Schema.string(
          description:
              'Optional example sentence for the term. Empty string when unavailable.',
        ),
      },
      requiredProperties: ['term', 'definition'],
    ),
  );

  /// Extract flashcards from an image using Gemini Flash.
  /// Tries models in order; falls back to the next on quota/rate errors.
  /// Returns a list of {term, definition, exampleSentence} maps.
  /// Throws [ScanException] with a specific reason on failure.
  static Future<List<Map<String, String>>> extractFlashcards({
    required String apiKey,
    required Uint8List imageBytes,
    required String mimeType,
    required PhotoScanMode mode,
  }) async {
    final compressedBytes = await _compressImage(imageBytes);
    if (kDebugMode) {
      debugPrint(
        'AI Scan: Original ${imageBytes.length} bytes -> Compressed ${compressedBytes.length} bytes',
      );
    }

    final prompt = switch (mode) {
      PhotoScanMode.vocabularyList => _vocabularyPrompt,
      PhotoScanMode.textbookPage => _textbookPrompt,
    };

    final content = Content.multi([
      TextPart(prompt),
      DataPart(mimeType, compressedBytes),
    ]);

    ScanException? lastError;

    for (final modelName in _models) {
      try {
        final response = await _generateWithFallback(
          apiKey: apiKey,
          modelName: modelName,
          content: content,
          prompt: prompt,
        ).timeout(_timeout);
        final text = response.text;
        if (text == null || text.trim().isEmpty) return [];

        final results = parseResponse(text);
        if (results.length > maxCards) {
          return results.sublist(0, maxCards);
        }
        return results;
      } on TimeoutException {
        lastError = ScanException(
          ScanFailureReason.timeout,
          'Request timed out',
        );
      } on GenerativeAIException catch (e) {
        final reason = AiErrorClassifier.classifySdkError(e.toString());
        lastError = ScanException(reason, e.toString());
        if (reason == ScanFailureReason.quotaExceeded) break;
        if (reason == ScanFailureReason.serverError) {
          continue;
        }
      } on FormatException catch (e) {
        lastError = ScanException(ScanFailureReason.parseError, e.toString());
      } catch (e) {
        if (e is ScanException) rethrow;
        lastError = ScanException(ScanFailureReason.networkError, e.toString());
      }
    }

    throw lastError ??
        ScanException(ScanFailureReason.unknown, 'All models failed');
  }

  static Future<List<Map<String, String>>> extractFlashcardsFromText({
    required String apiKey,
    required String ocrText,
    required PhotoScanMode mode,
  }) async {
    final basePrompt = switch (mode) {
      PhotoScanMode.vocabularyList => _vocabularyTextPrompt,
      PhotoScanMode.textbookPage => _textbookTextPrompt,
    };
    final prompt = '$basePrompt\n\n$_jsonOnlySuffix\n\nOCR text:\n$ocrText';
    final content = Content.text(prompt);

    ScanException? lastError;
    for (final modelName in _models) {
      try {
        final response = await _generateWithFallback(
          apiKey: apiKey,
          modelName: modelName,
          content: content,
          prompt: prompt,
        ).timeout(_timeout);
        final text = response.text;
        if (text == null || text.trim().isEmpty) return [];

        final results = parseResponse(text);
        if (results.length > maxCards) {
          return results.sublist(0, maxCards);
        }
        return results;
      } on TimeoutException {
        lastError = ScanException(
          ScanFailureReason.timeout,
          'Request timed out',
        );
      } on GenerativeAIException catch (e) {
        final reason = AiErrorClassifier.classifySdkError(e.toString());
        lastError = ScanException(reason, e.toString());
        if (reason == ScanFailureReason.quotaExceeded) break;
        if (reason == ScanFailureReason.serverError) {
          continue;
        }
      } on FormatException catch (e) {
        lastError = ScanException(ScanFailureReason.parseError, e.toString());
      } catch (e) {
        if (e is ScanException) rethrow;
        lastError = ScanException(ScanFailureReason.networkError, e.toString());
      }
    }

    throw lastError ??
        ScanException(ScanFailureReason.unknown, 'All models failed');
  }

  static Future<GenerateContentResponse> _generateWithFallback({
    required String apiKey,
    required String modelName,
    required Content content,
    required String prompt,
  }) async {
    try {
      final structuredModel = GenerativeModel(
        model: modelName,
        apiKey: apiKey,
        generationConfig: GenerationConfig(
          temperature: 0,
          maxOutputTokens: 2048,
          responseMimeType: 'application/json',
          responseSchema: _responseSchema,
        ),
      );
      return await structuredModel.generateContent([content]);
    } on GenerativeAIException catch (e) {
      final msg = e.toString().toLowerCase();
      final likelySchemaIssue =
          msg.contains('response_schema') ||
          msg.contains('responsemime') ||
          msg.contains('invalid argument') ||
          msg.contains('unsupported');
      if (!likelySchemaIssue) rethrow;
    }

    final jsonOnlyModel = GenerativeModel(
      model: modelName,
      apiKey: apiKey,
      generationConfig: GenerationConfig(temperature: 0, maxOutputTokens: 4096),
    );
    final dataParts = content.parts.whereType<DataPart>();
    final dataPart = dataParts.isEmpty ? null : dataParts.first;
    final jsonOnlyParts = <Part>[TextPart('$prompt $_jsonOnlySuffix')];
    if (dataPart != null) {
      jsonOnlyParts.add(dataPart);
    }
    final jsonOnlyContent = Content.multi(jsonOnlyParts);
    return jsonOnlyModel.generateContent([jsonOnlyContent]);
  }

  /// Parses Gemini response text into flashcard maps.
  /// Visible for testing.
  static List<Map<String, String>> parseResponse(String raw) {
    var cleaned = raw.trim();

    // Strip markdown code fences if present
    if (cleaned.startsWith('```')) {
      final firstNewline = cleaned.indexOf('\n');
      if (firstNewline != -1) {
        cleaned = cleaned.substring(firstNewline + 1);
      }
      if (cleaned.endsWith('```')) {
        cleaned = cleaned.substring(0, cleaned.length - 3).trim();
      }
    }

    // Extract JSON from response - find first [ or { and last ] or }
    final bracketIdx = cleaned.indexOf('[');
    final braceIdx = cleaned.indexOf('{');
    int startIdx = -1;
    if (bracketIdx != -1 && braceIdx != -1) {
      startIdx = bracketIdx < braceIdx ? bracketIdx : braceIdx;
    } else if (bracketIdx != -1) {
      startIdx = bracketIdx;
    } else if (braceIdx != -1) {
      startIdx = braceIdx;
    }
    if (startIdx != -1) {
      cleaned = cleaned.substring(startIdx);
      final lastBracket = cleaned.lastIndexOf(']');
      final lastBrace = cleaned.lastIndexOf('}');
      final endIdx = lastBracket > lastBrace ? lastBracket : lastBrace;
      if (endIdx != -1) {
        cleaned = cleaned.substring(0, endIdx + 1);
      }
    }

    final decoded = jsonDecode(cleaned);
    List<dynamic> items;

    if (decoded is List) {
      items = decoded;
    } else if (decoded is Map) {
      // Support {"cards": [...]} or {"flashcards": [...]} or any key with a list value
      final listValue = decoded.values.firstWhere(
        (v) => v is List,
        orElse: () => null,
      );
      if (listValue is List) {
        items = listValue;
      } else {
        return [];
      }
    } else {
      return [];
    }

    final results = <Map<String, String>>[];

    for (final item in items) {
      if (item is Map) {
        final term = (item['term'] ?? '').toString().trim();
        final definition = (item['definition'] ?? '').toString().trim();
        final exampleSentence = (item['exampleSentence'] ?? '')
            .toString()
            .trim();
        if (term.isNotEmpty && definition.isNotEmpty) {
          results.add({
            'term': term,
            'definition': definition,
            'exampleSentence': exampleSentence,
          });
        }
      }
    }

    return results;
  }

  /// Generates example sentences for a batch of terms.
  /// Returns a map of {term: exampleSentence}.
  static Future<Map<String, String>> generateExampleSentencesBatch({
    required String apiKey,
    required List<Map<String, String>> terms,
  }) async {
    if (terms.isEmpty) return {};

    final promptBuffer = StringBuffer();
    promptBuffer.writeln(
      'Generate a simple, natural example sentence for each of the following terms. '
      'The sentence should help understand the meaning of the term. '
      'Return ONLY a valid JSON array of objects with keys: "term", "exampleSentence". '
      'Do not include the definition in the output.',
    );
    promptBuffer.writeln('Terms:');
    for (final t in terms) {
      promptBuffer.writeln(
        '- Term: "${t['term']}", Meaning: "${t['definition']}"',
      );
    }

    final content = Content.text(promptBuffer.toString());

    for (final modelName in _models) {
      try {
        final response = await _generateWithFallback(
          apiKey: apiKey,
          modelName: modelName,
          content: content,
          prompt: promptBuffer.toString(),
        ).timeout(_timeout);

        final text = response.text;
        if (text == null || text.trim().isEmpty) continue;

        final results = parseResponse(text);
        final map = <String, String>{};
        for (final item in results) {
          final term = item['term'];
          final sentence = item['exampleSentence'];
          if (term != null && sentence != null && sentence.isNotEmpty) {
            map[term] = sentence;
          }
        }
        return map;
      } catch (e) {
        // Stop immediately on rate limit — retrying worsens the 429
        if (AiErrorClassifier.isRateLimit(AiErrorClassifier.classifySdkError(e.toString()))) break;
        continue;
      }
    }

    // If all fail
    return {};
  }

  static Future<Uint8List> _compressImage(Uint8List bytes) async {
    try {
      final compressed = await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: 1600,
        minHeight: 1600,
        quality: 85,
        format: CompressFormat.jpeg,
      );
      return compressed;
    } catch (e) {
      debugPrint('Image compression failed: $e');
      return bytes; // Fallback to original
    }
  }

  // -- Conversation Mode --

  /// Generates a random daily-life conversation scenario.
  static Future<ConversationScenario?> generateRandomScenario({
    required String apiKey,
    required String difficulty,
    required List<String> terms,
    List<String> avoidTitles = const <String>[],
  }) async {
    final avoid = avoidTitles
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(8)
        .join(' | ');
    final prompt =
        '''
Create one realistic daily-life English roleplay scenario for speaking practice.
Difficulty: $difficulty
Vocabulary the learner is studying: ${terms.take(8).join(', ')}
Do not reuse these recent scenario titles: ${avoid.isEmpty ? 'N/A' : avoid}
Requirements:
- Pick a concrete real-life situation where these words would naturally come up (infer the THEME from the words — e.g. shopping, travel, school, health, money). Do NOT force the words into the title/setting verbatim; just choose a fitting context.
- Include clear context: place + a concrete goal + at least one constraint (time/budget/urgency).
- Roles must be two different people, clear and useful for a learner to play one side.
- Title must be specific (not "Daily Conversation") and semantically different from all avoided titles.
- return ONLY a JSON object with keys:
  title, titleZh, setting, settingZh, aiRole, aiRoleZh, userRole, userRoleZh, stages, stagesZh
- stages must be an array of 5 short step strings describing how the conversation should progress.
- stagesZh must be Traditional Chinese and aligned with stages.
''';
    final text = await _generateLightweightJsonText(
      apiKey: apiKey,
      prompt: prompt,
    );
    if (text == null || text.trim().isEmpty) return null;
    final parsed = _parseScenario(text);
    if (parsed != null) {
      return parsed;
    }
    return null;
  }

  /// Generates short suggested replies to keep conversation going.
  static Future<List<ConversationReplySuggestion>> generateSuggestedReplies({
    required String apiKey,
    required String difficulty,
    required String scenarioTitle,
    required String aiRole,
    required String userRole,
    required String latestQuestion,
    required List<String> priorityTerms,
  }) async {
    final prompt =
        '''
Generate 3 short reply suggestions for the student.
Context:
- Scenario: $scenarioTitle
- AI role: $aiRole
- Student role: $userRole
- Difficulty: $difficulty
- Latest question: $latestQuestion
- Try to include these target words naturally when possible: ${priorityTerms.join(', ')}
Rules:
- Generate only 3 suggestions.
- Each suggestion must be 1 sentence, 5-10 words, practical, and easy to say out loud.
- Easy: simpler patterns. Hard: richer phrasing.
- Avoid generic lines like "I don't know" or "Can you explain?".
- Return ONLY JSON array of objects with keys:
  reply, zhHint, focusWord
- zhHint must be short Traditional Chinese guidance (max 16 chars).
''';
    final text = await _generateLightweightJsonText(
      apiKey: apiKey,
      prompt: prompt,
    );
    if (text == null || text.trim().isEmpty) {
      return const <ConversationReplySuggestion>[];
    }
    final suggestions = _parseReplySuggestions(text);
    if (suggestions.isNotEmpty) {
      return suggestions.take(3).toList();
    }
    return const <ConversationReplySuggestion>[];
  }

  static Future<String?> _generateLightweightJsonText({
    required String apiKey,
    required String prompt,
  }) async {
    final content = Content.text(prompt);
    for (final modelName in _lightweightModels) {
      try {
        final model = GenerativeModel(
          model: modelName,
          apiKey: apiKey,
          generationConfig: GenerationConfig(
            temperature: 0.4,
            maxOutputTokens: 512,
            responseMimeType: 'application/json',
          ),
        );
        final response = await model
            .generateContent([content])
            .timeout(_timeout);
        final text = response.text?.trim() ?? '';
        if (text.isNotEmpty) return text;
      } catch (e) {
        // Stop immediately on rate limit — retrying makes it worse
        if (AiErrorClassifier.isRateLimit(AiErrorClassifier.classifySdkError(e.toString()))) return null;
        continue;
      }
    }
    return null;
  }

  static ConversationScenario? _parseScenario(String raw) {
    try {
      var cleaned = raw.trim();
      final start = cleaned.indexOf('{');
      final end = cleaned.lastIndexOf('}');
      if (start != -1 && end != -1 && end > start) {
        cleaned = cleaned.substring(start, end + 1);
      }
      final decoded = jsonDecode(cleaned);
      if (decoded is! Map) return null;
      final title = (decoded['title'] ?? '').toString().trim();
      final titleZh = (decoded['titleZh'] ?? '').toString().trim();
      final setting = (decoded['setting'] ?? '').toString().trim();
      final settingZh = (decoded['settingZh'] ?? '').toString().trim();
      final aiRole = (decoded['aiRole'] ?? '').toString().trim();
      final aiRoleZh = (decoded['aiRoleZh'] ?? '').toString().trim();
      final userRole = (decoded['userRole'] ?? '').toString().trim();
      final userRoleZh = (decoded['userRoleZh'] ?? '').toString().trim();
      final stagesRaw = decoded['stages'];
      final stagesZhRaw = decoded['stagesZh'];
      final stages = stagesRaw is List
          ? stagesRaw
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList()
          : <String>[];
      final stagesZh = stagesZhRaw is List
          ? stagesZhRaw
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList()
          : <String>[];
      if (title.isEmpty ||
          setting.isEmpty ||
          aiRole.isEmpty ||
          userRole.isEmpty) {
        return null;
      }
      return ConversationScenario(
        title: title,
        titleZh: titleZh.isEmpty ? title : titleZh,
        setting: setting,
        settingZh: settingZh.isEmpty ? setting : settingZh,
        aiRole: aiRole,
        aiRoleZh: aiRoleZh.isEmpty ? aiRole : aiRoleZh,
        userRole: userRole,
        userRoleZh: userRoleZh.isEmpty ? userRole : userRoleZh,
        stages: stages.take(5).toList(),
        stagesZh: stagesZh.take(5).toList(),
      );
    } catch (_) {
      return null;
    }
  }

  static List<String> _parseStringArray(String raw) {
    try {
      var cleaned = raw.trim();
      final start = cleaned.indexOf('[');
      final end = cleaned.lastIndexOf(']');
      if (start != -1 && end != -1 && end > start) {
        cleaned = cleaned.substring(start, end + 1);
      }
      final decoded = jsonDecode(cleaned);
      if (decoded is! List) return const <String>[];
      return decoded
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    } catch (_) {
      return const <String>[];
    }
  }

  static List<ConversationReplySuggestion> _parseReplySuggestions(String raw) {
    try {
      var cleaned = raw.trim();
      final start = cleaned.indexOf('[');
      final end = cleaned.lastIndexOf(']');
      if (start != -1 && end != -1 && end > start) {
        cleaned = cleaned.substring(start, end + 1);
      }
      final decoded = jsonDecode(cleaned);
      if (decoded is! List) return const <ConversationReplySuggestion>[];
      final results = <ConversationReplySuggestion>[];
      for (final item in decoded) {
        if (item is Map) {
          final reply = (item['reply'] ?? '').toString().trim();
          final zhHint = (item['zhHint'] ?? '').toString().trim();
          final focusWord = (item['focusWord'] ?? '').toString().trim();
          if (reply.isEmpty) continue;
          results.add(
            ConversationReplySuggestion(
              reply: reply,
              zhHint: zhHint,
              focusWord: focusWord,
            ),
          );
          continue;
        }
        final fallback = item.toString().trim();
        if (fallback.isEmpty) continue;
        results.add(
          ConversationReplySuggestion(
            reply: fallback,
            zhHint: '',
            focusWord: '',
          ),
        );
      }
      return results;
    } catch (_) {
      final fallback = _parseStringArray(raw);
      return fallback
          .map(
            (line) => ConversationReplySuggestion(
              reply: line,
              zhHint: '',
              focusWord: '',
            ),
          )
          .toList();
    }
  }
}
