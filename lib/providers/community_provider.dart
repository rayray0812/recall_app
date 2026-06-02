import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/providers/auth_provider.dart';
import 'package:recall_app/providers/study_set_provider.dart';
import 'package:recall_app/services/community_service.dart';
import 'package:recall_app/services/local_storage_service.dart';

final communityServiceProvider = Provider<CommunityService>((ref) {
  final supabase = ref.watch(supabaseServiceProvider);
  return CommunityService(supabaseService: supabase);
});

/// Current sort option for public sets.
final communitySortProvider = StateProvider<CommunitySortOption>(
  (ref) => CommunitySortOption.trending,
);

/// Current category filter (empty = all).
final communityCategoryProvider = StateProvider<String>((ref) => '');

/// Query for fetching public study sets.
@immutable
class PublicSetsQuery {
  final String? search;
  final CommunitySortOption sort;
  final String category;

  const PublicSetsQuery({
    this.search,
    this.sort = CommunitySortOption.trending,
    this.category = '',
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PublicSetsQuery &&
          search == other.search &&
          sort == other.sort &&
          category == other.category;

  @override
  int get hashCode => Object.hash(search, sort, category);
}

/// Fetches public study sets with sort + category + search.
final publicStudySetsProvider =
    FutureProvider.family<List<PublicStudySet>, PublicSetsQuery>((
      ref,
      query,
    ) async {
      final service = ref.watch(communityServiceProvider);
      return service.fetchPublicSets(
        query: query.search,
        sort: query.sort,
        category: query.category,
      );
    });

/// Simple provider for backward compat: fetch by search string only.
final publicSetsBySearchProvider =
    FutureProvider.family<List<PublicStudySet>, String?>((ref, query) async {
      final service = ref.watch(communityServiceProvider);
      return service.fetchPublicSets(query: query);
    });

/// Checks if a given study set is published by the current user.
final isPublishedProvider = FutureProvider.family<bool, String>((
  ref,
  studySetId,
) async {
  ref.watch(currentUserProvider);
  final service = ref.watch(communityServiceProvider);
  return service.isPublished(studySetId);
});

/// Fetches a user's public profile.
final userProfileProvider = FutureProvider.family<UserPublicProfile, String>((
  ref,
  userId,
) async {
  final service = ref.watch(communityServiceProvider);
  return service.fetchUserProfile(userId);
});

/// Fetches public sets for a specific user.
final userPublicSetsProvider =
    FutureProvider.family<List<PublicStudySet>, String>((ref, userId) async {
      final service = ref.watch(communityServiceProvider);
      return service.fetchUserPublicSets(userId);
    });

final communityFriendIdsProvider =
    StateNotifierProvider<CommunityFriendIdsNotifier, List<String>>((ref) {
      final localStorage = ref.watch(localStorageServiceProvider);
      return CommunityFriendIdsNotifier(localStorage);
    });

final communitySavedSetIdsProvider =
    StateNotifierProvider<CommunitySavedSetIdsNotifier, List<String>>((ref) {
      final localStorage = ref.watch(localStorageServiceProvider);
      final service = ref.watch(communityServiceProvider);
      ref.watch(currentUserProvider);
      return CommunitySavedSetIdsNotifier(localStorage, service);
    });

final communityLikedSetIdsProvider =
    StateNotifierProvider<CommunityLikedSetIdsNotifier, List<String>>((ref) {
      final service = ref.watch(communityServiceProvider);
      ref.watch(currentUserProvider);
      return CommunityLikedSetIdsNotifier(service);
    });

final communityDownloadedSetIdsProvider = FutureProvider<List<String>>((
  ref,
) async {
  ref.watch(currentUserProvider);
  final service = ref.watch(communityServiceProvider);
  return service.fetchMyDownloadedSetIds();
});

class CommunityFriendIdsNotifier extends StateNotifier<List<String>> {
  CommunityFriendIdsNotifier(this._localStorage)
    : super(_localStorage.getCommunityFriendIds());

  final LocalStorageService _localStorage;

  Future<void> add(String userId) async {
    if (state.contains(userId)) return;
    final next = [...state, userId];
    await _localStorage.saveCommunityFriendIds(next);
    state = next;
  }

  Future<void> remove(String userId) async {
    final next = [...state]..removeWhere((id) => id == userId);
    await _localStorage.saveCommunityFriendIds(next);
    state = next;
  }
}

class CommunitySavedSetIdsNotifier extends StateNotifier<List<String>> {
  CommunitySavedSetIdsNotifier(this._localStorage, this._service)
    : super(_localStorage.getCommunitySavedSetIds()) {
    unawaited(_mergeFromCloud());
  }

  final LocalStorageService _localStorage;
  final CommunityService _service;

  Future<void> add(String publicSetId) async {
    if (state.contains(publicSetId)) return;
    final next = [...state, publicSetId];
    await _localStorage.saveCommunitySavedSetIds(next);
    state = next;
    await _service.setSaved(publicSetId, saved: true);
  }

  Future<void> remove(String publicSetId) async {
    final next = [...state]..removeWhere((id) => id == publicSetId);
    await _localStorage.saveCommunitySavedSetIds(next);
    state = next;
    await _service.setSaved(publicSetId, saved: false);
  }

  Future<void> toggle(String publicSetId) async {
    if (state.contains(publicSetId)) {
      await remove(publicSetId);
    } else {
      await add(publicSetId);
    }
  }

  Future<void> _mergeFromCloud() async {
    final cloudIds = await _service.fetchMySavedSetIds();
    if (!mounted) return;
    for (final localId in state.where((id) => !cloudIds.contains(id))) {
      await _service.setSaved(localId, saved: true);
    }
    if (!mounted) return;
    final merged = {...state, ...cloudIds}.toList();
    await _localStorage.saveCommunitySavedSetIds(merged);
    state = merged;
  }
}

class CommunityLikedSetIdsNotifier extends StateNotifier<List<String>> {
  CommunityLikedSetIdsNotifier(this._service) : super(const []) {
    unawaited(_refreshFromCloud());
  }

  final CommunityService _service;

  Future<void> toggle(String publicSetId) async {
    final liked = state.contains(publicSetId);
    state = liked
        ? ([...state]..removeWhere((id) => id == publicSetId))
        : [...state, publicSetId];
    await _service.setLiked(publicSetId, liked: !liked);
  }

  Future<void> _refreshFromCloud() async {
    final ids = await _service.fetchMyLikedSetIds();
    if (mounted) state = ids;
  }
}
