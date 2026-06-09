// Shared AI error types and classification logic used by all AI service adapters.
// Centralised here so Gemini SDK, Groq HTTP, and future providers all produce
// the same error vocabulary without duplicating string-matching logic.

/// Specific failure reasons used by [ScanException] and the UI error layer.
enum ScanFailureReason {
  timeout,
  quotaExceeded,
  authError,
  invalidRequest,
  serverError,
  parseError,
  networkError,
  unknown,
}

/// Exception thrown by AI service calls with a structured [ScanFailureReason].
class ScanException implements Exception {
  final ScanFailureReason reason;
  final String message;

  ScanException(this.reason, this.message);

  @override
  String toString() => message;
}

/// Classifies raw error signals from AI providers into [ScanFailureReason].
///
/// Two classification paths:
/// - [classifySdkError]: string-based, for Gemini generative AI SDK exceptions.
/// - [classifyHttpError]: status-code + body, for Groq and other REST endpoints.
abstract final class AiErrorClassifier {
  /// Classify a Gemini SDK error message string.
  static ScanFailureReason classifySdkError(String raw) {
    final msg = raw.toLowerCase();
    if (msg.contains('quota') ||
        msg.contains('rate limit') ||
        msg.contains('rate_limit') ||
        msg.contains('429') ||
        msg.contains('resource has been exhausted') ||
        msg.contains('resource_exhausted') ||
        msg.contains('too many requests')) {
      return ScanFailureReason.quotaExceeded;
    }
    if (msg.contains('api key not valid') ||
        msg.contains('unauthenticated') ||
        msg.contains('invalid session') ||
        msg.contains('permission denied') ||
        msg.contains('401') ||
        msg.contains('403')) {
      return ScanFailureReason.authError;
    }
    if (msg.contains('invalid argument') ||
        msg.contains('bad request') ||
        msg.contains('request contains an invalid') ||
        msg.contains('400')) {
      return ScanFailureReason.invalidRequest;
    }
    if (msg.contains('internal') ||
        msg.contains('unavailable') ||
        msg.contains('deadline exceeded') ||
        msg.contains('503') ||
        msg.contains('500')) {
      return ScanFailureReason.serverError;
    }
    if (msg.contains('failed host lookup') ||
        msg.contains('socketexception') ||
        msg.contains('network')) {
      return ScanFailureReason.networkError;
    }
    return ScanFailureReason.unknown;
  }

  /// Classify an HTTP error from a REST API endpoint.
  static ScanFailureReason classifyHttpError(int statusCode, String body) {
    if (statusCode == 429) return ScanFailureReason.quotaExceeded;
    if (statusCode == 401 || statusCode == 403) return ScanFailureReason.authError;
    if (statusCode == 400) return ScanFailureReason.invalidRequest;
    if (statusCode >= 500) return ScanFailureReason.serverError;

    final msg = body.toLowerCase();
    if (msg.contains('rate limit') || msg.contains('rate_limit')) {
      return ScanFailureReason.quotaExceeded;
    }
    if (msg.contains('api key') ||
        msg.contains('unauthenticated') ||
        msg.contains('invalid session')) {
      return ScanFailureReason.authError;
    }
    return ScanFailureReason.unknown;
  }

  /// Return true when [reason] means the caller should stop retrying immediately.
  static bool isRateLimit(ScanFailureReason reason) =>
      reason == ScanFailureReason.quotaExceeded;
}
