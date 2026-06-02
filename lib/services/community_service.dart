import 'package:flutter/foundation.dart';
import 'package:recall_app/core/constants/supabase_constants.dart';
import 'package:recall_app/models/flashcard.dart';
import 'package:recall_app/models/study_set.dart';
import 'package:recall_app/services/supabase_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Sort options for public study sets.
enum CommunitySortOption { trending, newest, mostDownloaded }

/// A public study set listing in the community.
class PublicStudySet {
  final String id;
  final String userId;
  final String studySetId;
  final String title;
  final String description;
  final List<Flashcard> cards;
  final String authorName;
  final List<String> tags;
  final String category;
  final int downloadCount;
  final int likeCount;
  final int saveCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  const PublicStudySet({
    required this.id,
    required this.userId,
    required this.studySetId,
    required this.title,
    this.description = '',
    this.cards = const [],
    this.authorName = '',
    this.tags = const [],
    this.category = '',
    this.downloadCount = 0,
    this.likeCount = 0,
    this.saveCount = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  factory PublicStudySet.fromJson(Map<String, dynamic> json) {
    final cardsJson = json['cards'] as List<dynamic>? ?? [];
    final cards = cardsJson.map((c) {
      final m = c as Map<String, dynamic>;
      return Flashcard(
        id: m['id'] as String? ?? const Uuid().v4(),
        term: m['term'] as String? ?? '',
        definition: m['definition'] as String? ?? '',
        imageUrl: m['imageUrl'] as String? ?? '',
        tags: (m['tags'] as List<dynamic>?)?.cast<String>() ?? const [],
      );
    }).toList();

    final tagsRaw = json['tags'];
    final tags = tagsRaw is List ? tagsRaw.cast<String>() : <String>[];

    return PublicStudySet(
      id: json['id'] as String? ?? '',
      userId: json['user_id'] as String? ?? '',
      studySetId: json['study_set_id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      cards: cards,
      authorName: json['author_name'] as String? ?? '',
      tags: tags,
      category: json['category'] as String? ?? '',
      downloadCount: (json['download_count'] as num?)?.toInt() ?? 0,
      likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
      saveCount: (json['save_count'] as num?)?.toInt() ?? 0,
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// User public profile stats.
class UserPublicProfile {
  final String userId;
  final String displayName;
  final int publishedCount;
  final int totalDownloads;

  const UserPublicProfile({
    required this.userId,
    this.displayName = '',
    this.publishedCount = 0,
    this.totalDownloads = 0,
  });
}

class CommunityService {
  final SupabaseService supabaseService;

  CommunityService({required this.supabaseService});

  SupabaseClient? get _client {
    if (!SupabaseConstants.isConfigured) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  /// Publish a study set to the community.
  Future<void> publishStudySet(
    StudySet studySet, {
    String category = '',
  }) async {
    final client = _client;
    if (client == null) throw Exception('Supabase not configured');
    final user = client.auth.currentUser;
    if (user == null) throw Exception('Must be logged in to publish');

    // Get author display name from profile or email
    String authorName = '';
    try {
      final profile = await client
          .from(SupabaseConstants.profilesTable)
          .select('display_name')
          .eq('user_id', user.id)
          .maybeSingle();
      authorName = (profile?['display_name'] as String?)?.trim() ?? '';
    } catch (_) {}
    if (authorName.isEmpty) {
      authorName = user.email?.split('@').first ?? 'Anonymous';
    }

    // Collect unique tags from cards
    final tags = <String>{};
    for (final card in studySet.cards) {
      for (final tag in card.tags) {
        if (tag.trim().isNotEmpty) tags.add(tag.trim());
      }
    }

    final cardsJson = studySet.cards
        .map(
          (c) => {
            'id': c.id,
            'term': c.term,
            'definition': c.definition,
            'imageUrl': c.imageUrl,
            'tags': c.tags,
          },
        )
        .toList();
    final nowIso = DateTime.now().toUtc().toIso8601String();
    String? existingId;
    String? createdAt;
    var downloadCount = 0;

    try {
      final existingRows = await client
          .from(SupabaseConstants.publicStudySetsTable)
          .select('id, download_count, created_at')
          .eq('user_id', user.id)
          .eq('study_set_id', studySet.id)
          .order('updated_at', ascending: false)
          .limit(1);
      if (existingRows.isNotEmpty) {
        final row = existingRows.first;
        existingId = row['id'] as String?;
        createdAt = row['created_at'] as String?;
        downloadCount = (row['download_count'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}

    final payload = {
      'id': existingId ?? const Uuid().v4(),
      'user_id': user.id,
      'study_set_id': studySet.id,
      'title': studySet.title,
      'description': studySet.description,
      'cards': cardsJson,
      'author_name': authorName,
      'tags': tags.toList(),
      'category': category,
      'download_count': downloadCount,
      'created_at': createdAt ?? nowIso,
      'updated_at': nowIso,
    };
    final retainedId = payload['id'] as String;

    if (existingId != null) {
      await client
          .from(SupabaseConstants.publicStudySetsTable)
          .update(payload)
          .eq('id', existingId);
    } else {
      await client.from(SupabaseConstants.publicStudySetsTable).insert(payload);
    }

    // Best-effort cleanup for legacy duplicate rows from earlier publishes.
    try {
      await client
          .from(SupabaseConstants.publicStudySetsTable)
          .delete()
          .eq('user_id', user.id)
          .eq('study_set_id', studySet.id)
          .neq('id', retainedId);
    } catch (_) {}
  }

  /// Fetch public study sets with optional search query, sorting, and category.
  Future<List<PublicStudySet>> fetchPublicSets({
    String? query,
    CommunitySortOption sort = CommunitySortOption.trending,
    String? category,
    int limit = 30,
    int offset = 0,
  }) async {
    final client = _client;
    if (client == null) return [];

    try {
      var builder = client
          .from(SupabaseConstants.publicStudySetsTable)
          .select();

      // Apply category filter
      if (category != null && category.isNotEmpty) {
        builder = builder.eq('category', category);
      }

      // Apply search filter
      if (query != null && query.trim().isNotEmpty) {
        final q = query.trim();
        builder = builder.or(
          'title.ilike.%$q%,description.ilike.%$q%,author_name.ilike.%$q%',
        );
      }

      // Apply sort + range (order returns a different type so we chain directly)
      late final dynamic data;
      switch (sort) {
        case CommunitySortOption.trending:
          data = await builder
              .order('like_count', ascending: false)
              .order('save_count', ascending: false)
              .order('download_count', ascending: false)
              .order('created_at', ascending: false)
              .range(offset, offset + limit - 1);
          break;
        case CommunitySortOption.newest:
          data = await builder
              .order('created_at', ascending: false)
              .range(offset, offset + limit - 1);
          break;
        case CommunitySortOption.mostDownloaded:
          data = await builder
              .order('download_count', ascending: false)
              .range(offset, offset + limit - 1);
          break;
      }

      return (data as List)
          .map((e) => PublicStudySet.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('CommunityService.fetchPublicSets error: $e');
      return [];
    }
  }

  /// Fetch public study sets published by a specific user.
  Future<List<PublicStudySet>> fetchUserPublicSets(String userId) async {
    final client = _client;
    if (client == null) return [];

    try {
      final data = await client
          .from(SupabaseConstants.publicStudySetsTable)
          .select()
          .eq('user_id', userId)
          .order('download_count', ascending: false);
      return (data as List)
          .map((e) => PublicStudySet.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('CommunityService.fetchUserPublicSets error: $e');
      return [];
    }
  }

  /// Fetch a user's public profile stats.
  Future<UserPublicProfile> fetchUserProfile(String userId) async {
    final client = _client;
    if (client == null) {
      return UserPublicProfile(userId: userId);
    }

    try {
      // Get display name
      String displayName = '';
      try {
        final profile = await client
            .from(SupabaseConstants.profilesTable)
            .select('display_name')
            .eq('user_id', userId)
            .maybeSingle();
        displayName = (profile?['display_name'] as String?)?.trim() ?? '';
      } catch (_) {}

      // Get stats via RPC
      final stats = await client.rpc(
        'get_user_public_stats',
        params: {'target_user_id': userId},
      );

      return UserPublicProfile(
        userId: userId,
        displayName: displayName,
        publishedCount: (stats?['published_count'] as int?) ?? 0,
        totalDownloads: (stats?['total_downloads'] as int?) ?? 0,
      );
    } catch (e) {
      debugPrint('CommunityService.fetchUserProfile error: $e');
      return UserPublicProfile(userId: userId);
    }
  }

  /// Submit a report for a public study set.
  Future<void> reportPublicSet({
    required String publicSetId,
    required String reason,
    String details = '',
  }) async {
    final client = _client;
    if (client == null) throw Exception('Supabase not configured');
    final user = client.auth.currentUser;
    if (user == null) throw Exception('Must be logged in to report');

    await client.from(SupabaseConstants.communityReportsTable).upsert({
      'reporter_id': user.id,
      'public_set_id': publicSetId,
      'reason': reason,
      'details': details,
    });
  }

  /// Increment download count for a public study set.
  Future<void> incrementDownloadCount(String publicSetId) async {
    final client = _client;
    if (client == null) return;

    try {
      await client.rpc(
        'record_community_download',
        params: {'set_id': publicSetId},
      );
    } catch (_) {
      try {
        await client.rpc(
          'increment_download_count',
          params: {'set_id': publicSetId},
        );
      } catch (_) {
        // Best effort — don't block the download.
      }
    }
  }

  Future<List<String>> fetchMyLikedSetIds() async {
    return _fetchMyInteractionSetIds(SupabaseConstants.communityLikesTable);
  }

  Future<List<String>> fetchMySavedSetIds() async {
    return _fetchMyInteractionSetIds(SupabaseConstants.communitySavesTable);
  }

  Future<List<String>> fetchMyDownloadedSetIds() async {
    return _fetchMyInteractionSetIds(SupabaseConstants.communityDownloadsTable);
  }

  Future<List<String>> _fetchMyInteractionSetIds(String table) async {
    final client = _client;
    final user = client?.auth.currentUser;
    if (client == null || user == null) return [];

    try {
      final rows = await client
          .from(table)
          .select('public_set_id')
          .eq('user_id', user.id);
      return (rows as List)
          .map(
            (row) => (row as Map<String, dynamic>)['public_set_id'] as String,
          )
          .toList();
    } catch (e) {
      debugPrint('CommunityService._fetchMyInteractionSetIds error: $e');
      return [];
    }
  }

  Future<void> setLiked(String publicSetId, {required bool liked}) async {
    await _setInteraction(
      SupabaseConstants.communityLikesTable,
      publicSetId,
      enabled: liked,
    );
  }

  Future<void> setSaved(String publicSetId, {required bool saved}) async {
    await _setInteraction(
      SupabaseConstants.communitySavesTable,
      publicSetId,
      enabled: saved,
    );
  }

  Future<void> _setInteraction(
    String table,
    String publicSetId, {
    required bool enabled,
  }) async {
    final client = _client;
    final user = client?.auth.currentUser;
    if (client == null || user == null) return;

    try {
      if (enabled) {
        await client.from(table).upsert({
          'user_id': user.id,
          'public_set_id': publicSetId,
        });
      } else {
        await client
            .from(table)
            .delete()
            .eq('user_id', user.id)
            .eq('public_set_id', publicSetId);
      }
    } catch (e) {
      debugPrint('CommunityService._setInteraction error: $e');
    }
  }

  /// Unpublish a study set (owner only).
  Future<void> unpublishStudySet(String studySetId) async {
    final client = _client;
    if (client == null) return;
    final user = client.auth.currentUser;
    if (user == null) return;

    await client
        .from(SupabaseConstants.publicStudySetsTable)
        .delete()
        .eq('study_set_id', studySetId)
        .eq('user_id', user.id);
  }

  /// Check if a study set is already published by the current user.
  Future<bool> isPublished(String studySetId) async {
    final client = _client;
    if (client == null) return false;
    final user = client.auth.currentUser;
    if (user == null) return false;

    try {
      final data = await client
          .from(SupabaseConstants.publicStudySetsTable)
          .select('id')
          .eq('study_set_id', studySetId)
          .eq('user_id', user.id)
          .maybeSingle();
      return data != null;
    } catch (_) {
      return false;
    }
  }

  /// Finds an existing local set that already matches a public set.
  StudySet? findMatchingLocalStudySet(
    PublicStudySet publicSet,
    Iterable<StudySet> localSets,
  ) {
    for (final localSet in localSets) {
      if (matchesLocalStudySet(publicSet, localSet)) {
        return localSet;
      }
    }
    return null;
  }

  /// Compares a public set against a local set by normalized content.
  bool matchesLocalStudySet(PublicStudySet publicSet, StudySet? localSet) {
    if (localSet == null) return false;
    if (_normalizeText(localSet.title) != _normalizeText(publicSet.title)) {
      return false;
    }
    if (localSet.cards.length != publicSet.cards.length) return false;

    final localKeys = localSet.cards
        .map((card) => _cardKey(card.term, card.definition))
        .toSet();
    final publicKeys = publicSet.cards
        .map((card) => _cardKey(card.term, card.definition))
        .toSet();
    return localKeys.length == publicKeys.length &&
        localKeys.containsAll(publicKeys);
  }

  /// Convert a public study set to a local StudySet for saving.
  StudySet toLocalStudySet(PublicStudySet publicSet) {
    final newId = const Uuid().v4();
    final newCards = publicSet.cards
        .map(
          (c) => Flashcard(
            id: const Uuid().v4(),
            term: c.term,
            definition: c.definition,
            imageUrl: c.imageUrl,
            tags: c.tags,
          ),
        )
        .toList();

    return StudySet(
      id: newId,
      title: publicSet.title,
      description: publicSet.description,
      createdAt: DateTime.now(),
      cards: newCards,
    );
  }

  String _cardKey(String term, String definition) {
    return '${_normalizeText(term)}|${_normalizeText(definition)}';
  }

  String _normalizeText(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }
}
