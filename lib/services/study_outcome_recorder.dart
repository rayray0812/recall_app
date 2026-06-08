import 'package:recall_app/models/card_progress.dart';
import 'package:recall_app/models/review_log.dart';
import 'package:recall_app/services/fsrs_service.dart';
import 'package:recall_app/services/local_storage_service.dart';

/// Centralizes study-mode outcomes into FSRS progress + review logs.
///
/// Game-like modes should emit semantic ratings through this recorder instead
/// of each screen knowing how to initialize progress and write logs.
class StudyOutcomeRecorder {
  final LocalStorageService _localStorage;
  final FsrsService _fsrsService;

  const StudyOutcomeRecorder({
    required LocalStorageService localStorage,
    required FsrsService fsrsService,
  }) : _localStorage = localStorage,
       _fsrsService = fsrsService;

  Future<ReviewLog> recordRating({
    required String cardId,
    required String setId,
    required int rating,
    required String reviewType,
    String? sessionId,
    int? responseLatencyMs,
    String? chosenDistractorId,
    double? predictedRetrievability,
    int? speakingScore,
    Map<String, dynamic>? metadata,
  }) async {
    final existingProgress = _localStorage.getCardProgress(cardId);
    final progress =
        existingProgress ?? CardProgress(cardId: cardId, setId: setId);

    final result = _fsrsService.reviewCard(progress, rating);
    final log = result.log.copyWith(
      reviewType: reviewType,
      sessionId: sessionId,
      responseLatencyMs: responseLatencyMs,
      chosenDistractorId: chosenDistractorId,
      predictedRetrievability: predictedRetrievability,
      speakingScore: speakingScore,
      metadata: metadata,
    );

    await _localStorage.saveCardProgress(result.progress);
    await _localStorage.saveReviewLog(log);
    return log;
  }
}
