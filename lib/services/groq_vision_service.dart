import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;
import 'package:recall_app/services/ai_error.dart';
import 'package:recall_app/services/gemini_service.dart';

/// Groq Cloud API service using Llama 4 Scout.
/// Free tier (~1,000 req/day), no credit card required.
///
/// Preferred pipeline: **OCR + Text AI** — on-device OCR reads the image,
/// then Groq text model structures it into flashcards (no image upload needed).
/// Falls back to Vision API when OCR text is insufficient.
class GroqVisionService {
  static const _endpoint =
      'https://api.groq.com/openai/v1/chat/completions';
  static const _model = 'meta-llama/llama-4-scout-17b-16e-instruct';
  static const _textModel = 'meta-llama/llama-4-scout-17b-16e-instruct';
  static const _timeout = Duration(seconds: 45);
  static const _textTimeout = Duration(seconds: 30);
  static const maxCards = 300;

  /// Minimum OCR text length to use text-only mode.
  static const _minOcrTextLength = 30;

  static const _vocabularyPrompt =
      'Extract all term-definition pairs from this vocabulary list/word table image. '
      'Keep original language. For bilingual content, use one language as term and the other as definition. '
      'Skip headers, page numbers, section titles, numbering-only rows, and decorative text. '
      'Do NOT output items where term and definition are the same text. '
      'Do NOT guess when text is unreadable; skip uncertain rows. '
      'Preserve row pairing strictly (same row left/right). '
      'exampleSentence is optional: ONLY extract it when a sentence is explicitly visible in the same entry/row. '
      'Do NOT generate new example sentences. If none is visible, return empty string for exampleSentence.';

  static const _textbookPrompt =
      'Extract 5-15 key concepts from this textbook/study material image as flashcard pairs. '
      'Create concise term (question/concept) and definition (answer/explanation). '
      'Keep original language. Focus on testable knowledge points. '
      'Skip page titles, headers/footers, page numbers, labels, and standalone fragments. '
      'Do NOT output duplicate concepts or same-text term/definition pairs. '
      'If uncertain, skip the item instead of guessing. '
      'exampleSentence is optional: ONLY extract it if a matching sentence is explicitly visible. '
      'Do NOT generate new example sentences; otherwise use empty string.';

  static const _vocabularyTextPrompt =
      'The following text was extracted by OCR from a vocabulary list image. '
      'Structure it into term-definition pairs. '
      'Keep original language. For bilingual content, use one language as term and the other as definition. '
      'Skip headers, page numbers, section titles, numbering-only rows, and decorative text. '
      'Do NOT output items where term and definition are the same text. '
      'Preserve row pairing strictly. '
      'exampleSentence is optional: ONLY include it if a sentence is clearly present in the same entry. '
      'Do NOT generate new example sentences; use empty string if none.';

  static const _textbookTextPrompt =
      'The following text was extracted by OCR from a textbook page. '
      'Extract 5-15 key concepts as flashcard pairs. '
      'Create concise term (question/concept) and definition (answer/explanation). '
      'Keep original language. Focus on testable knowledge points. '
      'Skip page titles, headers/footers, labels, and standalone fragments. '
      'Do NOT output duplicate concepts or same-text term/definition pairs. '
      'exampleSentence is optional: ONLY include it if explicitly present. '
      'Do NOT generate new example sentences; use empty string if none.';

  static const _jsonSuffix =
      'Return ONLY a valid JSON array. Each item must be: '
      '{"term":"...","definition":"...","exampleSentence":"..."} '
      'Exclude duplicates and invalid/noisy rows.';

  /// Extract flashcards from an image using Groq Vision (Llama 4 Scout).
  /// Reuses [GeminiService.parseResponse] for JSON parsing and
  /// [ScanException] / [ScanFailureReason] for error classification.
  static Future<List<Map<String, String>>> extractFlashcards({
    required String apiKey,
    required Uint8List imageBytes,
    required String mimeType,
    required PhotoScanMode mode,
    String? ocrHintText,
  }) async {
    final compressedBytes = await _compressImage(imageBytes);
    if (kDebugMode) {
      debugPrint(
        'Groq Scan: Original ${imageBytes.length} bytes -> '
        'Compressed ${compressedBytes.length} bytes',
      );
    }

    final basePrompt = switch (mode) {
      PhotoScanMode.vocabularyList => _vocabularyPrompt,
      PhotoScanMode.textbookPage => _textbookPrompt,
    };

    final prompt = (ocrHintText != null && ocrHintText.trim().length >= 10)
        ? 'On-device OCR detected the following text in this image (may contain errors, '
          'use as reference only — always verify against the image):\n'
          '---\n${ocrHintText.trim()}\n---\n\n$basePrompt\n\n$_jsonSuffix'
        : '$basePrompt\n\n$_jsonSuffix';

    final base64Image = base64Encode(compressedBytes);
    final dataUri = 'data:$mimeType;base64,$base64Image';

    final body = jsonEncode({
      'model': _model,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': prompt},
            {
              'type': 'image_url',
              'image_url': {'url': dataUri},
            },
          ],
        },
      ],
      'response_format': {'type': 'json_object'},
      'temperature': 0,
      'max_tokens': 8192,
    });

    try {
      final response = await http
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(_timeout);

      if (response.statusCode != 200) {
        final reason = AiErrorClassifier.classifyHttpError(response.statusCode, response.body);
        // Classify from the body, but don't embed it in the message/logs.
        throw ScanException(reason, 'Groq API error ${response.statusCode}');
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = json['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) return [];

      final message = choices[0]['message'] as Map<String, dynamic>?;
      final text = message?['content']?.toString() ?? '';
      if (text.trim().isEmpty) return [];

      final results = GeminiService.parseResponse(text);
      if (results.length > maxCards) {
        return results.sublist(0, maxCards);
      }
      return results;
    } on TimeoutException {
      throw ScanException(ScanFailureReason.timeout, 'Request timed out');
    } on ScanException {
      rethrow;
    } on FormatException catch (e) {
      throw ScanException(ScanFailureReason.parseError, e.toString());
    } catch (e) {
      throw ScanException(ScanFailureReason.networkError, e.toString());
    }
  }

  /// Whether the OCR text is sufficient for text-only mode.
  static bool canUseTextOnly(String? ocrText) {
    return ocrText != null && ocrText.trim().length >= _minOcrTextLength;
  }

  /// Extract flashcards from OCR text only (no image upload).
  /// Much faster and more accurate than Vision for structured text.
  static Future<List<Map<String, String>>> extractFlashcardsFromText({
    required String apiKey,
    required String ocrText,
    required PhotoScanMode mode,
  }) async {
    if (kDebugMode) {
      debugPrint('Groq Text-only: ${ocrText.length} chars OCR input');
    }

    final basePrompt = switch (mode) {
      PhotoScanMode.vocabularyList => _vocabularyTextPrompt,
      PhotoScanMode.textbookPage => _textbookTextPrompt,
    };

    final prompt = '$basePrompt\n\n$_jsonSuffix\n\n'
        'OCR text:\n---\n${ocrText.trim()}\n---';

    final body = jsonEncode({
      'model': _textModel,
      'messages': [
        {
          'role': 'user',
          'content': prompt,
        },
      ],
      'response_format': {'type': 'json_object'},
      'temperature': 0,
      'max_tokens': 8192,
    });

    try {
      final response = await http
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(_textTimeout);

      if (response.statusCode != 200) {
        final reason = AiErrorClassifier.classifyHttpError(response.statusCode, response.body);
        // Classify from the body, but don't embed it in the message/logs.
        throw ScanException(
          reason,
          'Groq API error ${response.statusCode}',
        );
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = json['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) return [];

      final message = choices[0]['message'] as Map<String, dynamic>?;
      final text = message?['content']?.toString() ?? '';
      if (text.trim().isEmpty) return [];

      final results = GeminiService.parseResponse(text);
      if (results.length > maxCards) {
        return results.sublist(0, maxCards);
      }
      return results;
    } on TimeoutException {
      throw ScanException(ScanFailureReason.timeout, 'Request timed out');
    } on ScanException {
      rethrow;
    } on FormatException catch (e) {
      throw ScanException(ScanFailureReason.parseError, e.toString());
    } catch (e) {
      throw ScanException(ScanFailureReason.networkError, e.toString());
    }
  }

  /// Builds the text-only request body map (visible for testing).
  static Map<String, dynamic> buildTextRequestBody({
    required String prompt,
  }) {
    return {
      'model': _textModel,
      'messages': [
        {
          'role': 'user',
          'content': prompt,
        },
      ],
      'response_format': {'type': 'json_object'},
      'temperature': 0,
      'max_tokens': 8192,
    };
  }

  /// Builds the request body map (visible for testing).
  static Map<String, dynamic> buildRequestBody({
    required String prompt,
    required String dataUri,
  }) {
    return {
      'model': _model,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': prompt},
            {
              'type': 'image_url',
              'image_url': {'url': dataUri},
            },
          ],
        },
      ],
      'response_format': {'type': 'json_object'},
      'temperature': 0,
      'max_tokens': 8192,
    };
  }

  static Future<Uint8List> _compressImage(Uint8List bytes) async {
    try {
      if (bytes.length <= 1.2 * 1024 * 1024) {
        return bytes;
      }
      final compressed = await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: 2200,
        minHeight: 2200,
        quality: 92,
        format: CompressFormat.jpeg,
      );
      return compressed;
    } catch (e) {
      debugPrint('Image compression failed: $e');
      return bytes;
    }
  }
}
