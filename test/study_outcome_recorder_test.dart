import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recall_app/core/constants/app_constants.dart';
import 'package:recall_app/models/adapters/card_progress_adapter.dart';
import 'package:recall_app/models/adapters/review_log_adapter.dart';
import 'package:recall_app/services/fsrs_service.dart';
import 'package:recall_app/services/local_storage_service.dart';
import 'package:recall_app/services/study_outcome_recorder.dart';

void main() {
  late Directory tempDir;
  late LocalStorageService localStorage;
  late StudyOutcomeRecorder recorder;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'Recall-study-outcome-recorder-',
    );
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(CardProgressAdapter());
    }
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(ReviewLogAdapter());
    }
    await Hive.openBox(AppConstants.hiveCardProgressBox);
    await Hive.openBox(AppConstants.hiveReviewLogsBox);
  });

  tearDownAll(() async {
    await Hive.box(AppConstants.hiveCardProgressBox).clear();
    await Hive.box(AppConstants.hiveReviewLogsBox).clear();
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  setUp(() async {
    localStorage = LocalStorageService();
    recorder = StudyOutcomeRecorder(
      localStorage: localStorage,
      fsrsService: FsrsService(),
    );
    await Hive.box(AppConstants.hiveCardProgressBox).clear();
    await Hive.box(AppConstants.hiveReviewLogsBox).clear();
  });

  test('creates missing progress and writes review log metadata', () async {
    final log = await recorder.recordRating(
      cardId: 'card-1',
      setId: 'set-1',
      rating: 3,
      reviewType: 'learn',
      chosenDistractorId: 'card-2',
      metadata: <String, dynamic>{'stageBefore': 1, 'stageAfter': 2},
    );

    final progress = localStorage.getCardProgress('card-1');
    final storedLog = localStorage.getReviewLog(log.id);

    expect(progress, isNotNull);
    expect(progress!.cardId, 'card-1');
    expect(progress.setId, 'set-1');
    expect(progress.reps, 1);
    expect(progress.isSynced, isFalse);

    expect(storedLog, isNotNull);
    expect(storedLog!.reviewType, 'learn');
    expect(storedLog.rating, 3);
    expect(storedLog.chosenDistractorId, 'card-2');
    expect(storedLog.metadata?['stageBefore'], 1);
    expect(storedLog.metadata?['stageAfter'], 2);
  });
}
