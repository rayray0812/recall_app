import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recall_app/core/constants/app_constants.dart';
import 'package:recall_app/models/adapters/folder_adapter.dart';
import 'package:recall_app/models/adapters/study_set_adapter.dart';
import 'package:recall_app/models/flashcard.dart';
import 'package:recall_app/models/adapters/review_log_adapter.dart';
import 'package:recall_app/models/review_log.dart';
import 'package:recall_app/models/study_set.dart';
import 'package:recall_app/services/local_storage_service.dart';

void main() {
  late Directory tempDir;
  late LocalStorageService service;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('Recall-hive-test-');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(ReviewLogAdapter());
    }
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(StudySetAdapter());
    }
    if (!Hive.isAdapterRegistered(4)) {
      Hive.registerAdapter(FolderAdapter());
    }
    await Hive.openBox(AppConstants.hiveStudySetsBox);
    await Hive.openBox(AppConstants.hiveCardProgressBox);
    await Hive.openBox(AppConstants.hiveReviewLogsBox);
    await Hive.openBox(AppConstants.hiveSettingsBox);
    await Hive.openBox(AppConstants.hiveFoldersBox);
  });

  tearDownAll(() async {
    await Hive.box(AppConstants.hiveReviewLogsBox).clear();
    await Hive.box(AppConstants.hiveCardProgressBox).clear();
    await Hive.box(AppConstants.hiveStudySetsBox).clear();
    await Hive.box(AppConstants.hiveSettingsBox).clear();
    await Hive.box(AppConstants.hiveFoldersBox).clear();
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  setUp(() async {
    service = LocalStorageService();
    await Hive.box(AppConstants.hiveReviewLogsBox).clear();
    await Hive.box(AppConstants.hiveStudySetsBox).clear();
    await Hive.box(AppConstants.hiveSettingsBox).clear();
    await Hive.box(AppConstants.hiveFoldersBox).clear();
  });

  test('getReviewLogsForDate includes exact start-of-day boundary', () async {
    final day = DateTime.utc(2026, 2, 6);

    await service.saveReviewLog(
      ReviewLog(
        id: 'start',
        cardId: 'c1',
        setId: 's1',
        rating: 3,
        state: 0,
        reviewedAt: day,
      ),
    );
    await service.saveReviewLog(
      ReviewLog(
        id: 'inside',
        cardId: 'c2',
        setId: 's1',
        rating: 4,
        state: 1,
        reviewedAt: day.add(const Duration(hours: 12)),
      ),
    );
    await service.saveReviewLog(
      ReviewLog(
        id: 'outside',
        cardId: 'c3',
        setId: 's1',
        rating: 2,
        state: 1,
        reviewedAt: day.subtract(const Duration(seconds: 1)),
      ),
    );

    final logs = service.getReviewLogsForDate(day);
    final ids = logs.map((e) => e.id).toSet();

    expect(ids, contains('start'));
    expect(ids, contains('inside'));
    expect(ids, isNot(contains('outside')));
  });

  test(
    'getReviewLogsInRange includes from-boundary and excludes to-boundary',
    () async {
      final from = DateTime.utc(2026, 2, 1);
      final to = DateTime.utc(2026, 2, 2);

      await service.saveReviewLog(
        ReviewLog(
          id: 'from',
          cardId: 'c1',
          setId: 's1',
          rating: 3,
          state: 0,
          reviewedAt: from,
        ),
      );
      await service.saveReviewLog(
        ReviewLog(
          id: 'middle',
          cardId: 'c2',
          setId: 's1',
          rating: 1,
          state: 1,
          reviewedAt: from.add(const Duration(hours: 8)),
        ),
      );
      await service.saveReviewLog(
        ReviewLog(
          id: 'to',
          cardId: 'c3',
          setId: 's1',
          rating: 2,
          state: 1,
          reviewedAt: to,
        ),
      );

      final logs = service.getReviewLogsInRange(from, to);
      final ids = logs.map((e) => e.id).toSet();

      expect(ids, contains('from'));
      expect(ids, contains('middle'));
      expect(ids, isNot(contains('to')));
    },
  );

  test('markStudySetDeleted stores unique tombstone ids', () async {
    await service.markStudySetDeleted('set_1');
    await service.markStudySetDeleted('set_1');
    await service.markStudySetDeleted('set_2');

    final ids = service.getDeletedStudySetIds();
    expect(ids, ['set_1', 'set_2']);
  });

  test('markFolderDeleted stores unique tombstone ids', () async {
    await service.markFolderDeleted('folder_1');
    await service.markFolderDeleted('folder_1');
    await service.markFolderDeleted('folder_2');

    final ids = service.getDeletedFolderIds();
    expect(ids, ['folder_1', 'folder_2']);
  });

  test('community saved set ids are unique and removable', () async {
    await service.addCommunitySavedSetId('public_1');
    await service.addCommunitySavedSetId('public_1');
    await service.addCommunitySavedSetId('public_2');

    expect(service.getCommunitySavedSetIds(), ['public_1', 'public_2']);

    await service.removeCommunitySavedSetId('public_1');

    expect(service.getCommunitySavedSetIds(), ['public_2']);
  });

  test('clearAllUserData clears community friend and saved set ids', () async {
    await service.addCommunityFriendId('user_1');
    await service.addCommunitySavedSetId('public_1');

    await service.clearAllUserData();

    expect(service.getCommunityFriendIds(), isEmpty);
    expect(service.getCommunitySavedSetIds(), isEmpty);
  });

  test(
    'clearFolderReference removes folderId and marks sets unsynced',
    () async {
      final linked = StudySet(
        id: 'set_1',
        title: 'Linked',
        createdAt: DateTime.utc(2026, 3, 7),
        cards: const [Flashcard(id: 'c1', term: 'a', definition: 'b')],
        folderId: 'folder_1',
        isSynced: true,
      );
      final untouched = StudySet(
        id: 'set_2',
        title: 'Other',
        createdAt: DateTime.utc(2026, 3, 7),
        cards: const [Flashcard(id: 'c2', term: 'c', definition: 'd')],
        folderId: 'folder_2',
        isSynced: true,
      );

      await service.saveStudySet(linked);
      await service.saveStudySet(untouched);

      await service.clearFolderReference('folder_1');

      final updatedLinked = service.getStudySet('set_1');
      final updatedUntouched = service.getStudySet('set_2');

      expect(updatedLinked, isNotNull);
      expect(updatedLinked!.folderId, isNull);
      expect(updatedLinked.isSynced, isFalse);
      expect(updatedLinked.updatedAt, isNotNull);

      expect(updatedUntouched, isNotNull);
      expect(updatedUntouched!.folderId, 'folder_2');
      expect(updatedUntouched.isSynced, isTrue);
    },
  );

  test('deleteReviewLogsForSet removes only target set logs', () async {
    await service.saveReviewLog(
      ReviewLog(
        id: 'a1',
        cardId: 'c1',
        setId: 'set_a',
        rating: 3,
        state: 0,
        reviewedAt: DateTime.utc(2026, 2, 15, 8),
      ),
    );
    await service.saveReviewLog(
      ReviewLog(
        id: 'a2',
        cardId: 'c2',
        setId: 'set_a',
        rating: 4,
        state: 1,
        reviewedAt: DateTime.utc(2026, 2, 15, 9),
      ),
    );
    await service.saveReviewLog(
      ReviewLog(
        id: 'b1',
        cardId: 'c3',
        setId: 'set_b',
        rating: 2,
        state: 1,
        reviewedAt: DateTime.utc(2026, 2, 15, 10),
      ),
    );

    await service.deleteReviewLogsForSet('set_a');
    final remainingIds = service.getAllReviewLogs().map((e) => e.id).toSet();

    expect(remainingIds, {'b1'});
  });
}
