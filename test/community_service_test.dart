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
      'average_rating': 4.25,
      'rating_count': 8,
      'comment_count': 3,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });

    expect(publicSet.downloadCount, 12);
    expect(publicSet.likeCount, 7);
    expect(publicSet.saveCount, 5);
    expect(publicSet.averageRating, 4.25);
    expect(publicSet.ratingCount, 8);
    expect(publicSet.commentCount, 3);
  });

  test('CommunityComment.fromJson parses moderation state', () {
    final comment = CommunityComment.fromJson({
      'id': 'comment-1',
      'public_set_id': 'public-1',
      'user_id': 'user-2',
      'author_name': 'Ray',
      'body': 'Useful set',
      'is_hidden': true,
      'created_at': now.toIso8601String(),
    });

    expect(comment.id, 'comment-1');
    expect(comment.authorName, 'Ray');
    expect(comment.body, 'Useful set');
    expect(comment.isHidden, isTrue);
  });

  group('sanitizeSearchTerm', () {
    test('returns empty for null or blank input', () {
      expect(CommunityService.sanitizeSearchTerm(null), '');
      expect(CommunityService.sanitizeSearchTerm('   '), '');
    });

    test('strips PostgREST filter-structural characters', () {
      // Commas/parens/colons/asterisks would let a user inject extra .or()
      // conditions or break out of the ilike pattern.
      expect(CommunityService.sanitizeSearchTerm('a,b(c)d:e*f'), 'a b c d e f');
      expect(
        CommunityService.sanitizeSearchTerm('title.ilike.%x%,user_id.eq.1'),
        contains('title.ilike'),
      );
      expect(
        CommunityService.sanitizeSearchTerm('title.ilike.%x%,user_id.eq.1'),
        isNot(contains(',')),
      );
    });

    test('strips SQL LIKE wildcards and backslash', () {
      final result = CommunityService.sanitizeSearchTerm(r'50%_off\now');
      expect(result, isNot(contains('%')));
      expect(result, isNot(contains('_')));
      expect(result, isNot(contains(r'\')));
    });

    test('collapses whitespace and trims', () {
      expect(CommunityService.sanitizeSearchTerm('  hello   world  '),
          'hello world');
    });

    test('caps length at 100 characters', () {
      final long = 'a' * 250;
      expect(CommunityService.sanitizeSearchTerm(long).length, 100);
    });

    test('preserves ordinary search terms (incl. CJK)', () {
      expect(CommunityService.sanitizeSearchTerm('生物 細胞'), '生物 細胞');
    });
  });
}
