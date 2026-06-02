import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/models/flashcard.dart';
import 'package:recall_app/models/study_set.dart';
import 'package:recall_app/services/community_service.dart';
import 'package:recall_app/services/supabase_service.dart';

void main() {
  final service = CommunityService(supabaseService: SupabaseService());
  final now = DateTime.utc(2026, 3, 31, 10);

  PublicStudySet buildPublicSet({
    String title = 'Biology Basics',
    List<Flashcard>? cards,
  }) {
    return PublicStudySet(
      id: 'public-1',
      userId: 'user-1',
      studySetId: 'study-1',
      title: title,
      cards:
          cards ??
          const [
            Flashcard(id: 'c1', term: ' Cell ', definition: ' Basic unit '),
            Flashcard(id: 'c2', term: 'DNA', definition: 'Genetic material'),
          ],
      createdAt: now,
      updatedAt: now,
    );
  }

  StudySet buildLocalSet({
    String title = 'biology basics',
    List<Flashcard>? cards,
  }) {
    return StudySet(
      id: 'local-1',
      title: title,
      createdAt: now,
      cards:
          cards ??
          const [
            Flashcard(id: 'l1', term: 'cell', definition: 'basic unit'),
            Flashcard(id: 'l2', term: 'DNA', definition: 'genetic material'),
          ],
    );
  }

  test('matchesLocalStudySet ignores case and extra whitespace', () {
    expect(
      service.matchesLocalStudySet(buildPublicSet(), buildLocalSet()),
      isTrue,
    );
  });

  test('matchesLocalStudySet rejects different card content', () {
    final localSet = buildLocalSet(
      cards: const [
        Flashcard(id: 'l1', term: 'Cell', definition: 'Basic unit'),
        Flashcard(id: 'l2', term: 'RNA', definition: 'Messenger'),
      ],
    );

    expect(service.matchesLocalStudySet(buildPublicSet(), localSet), isFalse);
  });

  test('findMatchingLocalStudySet returns existing equivalent set', () {
    final existing = buildLocalSet();
    final different = StudySet(
      id: 'local-2',
      title: 'Physics',
      createdAt: now,
      cards: const [
        Flashcard(id: 'p1', term: 'Force', definition: 'Push or pull'),
      ],
    );

    final match = service.findMatchingLocalStudySet(buildPublicSet(), [
      different,
      existing,
    ]);

    expect(match?.id, existing.id);
  });

  test('PublicStudySet.fromJson parses interaction counts', () {
    final publicSet = PublicStudySet.fromJson({
      'id': 'public-1',
      'user_id': 'user-1',
      'study_set_id': 'study-1',
      'title': 'Biology Basics',
      'download_count': 12,
      'like_count': 7,
      'save_count': 5,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });

    expect(publicSet.downloadCount, 12);
    expect(publicSet.likeCount, 7);
    expect(publicSet.saveCount, 5);
  });
}
