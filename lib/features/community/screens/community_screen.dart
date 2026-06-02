import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/core/theme/app_theme.dart';
import 'package:recall_app/models/classroom.dart';
import 'package:recall_app/models/study_set.dart';
import 'package:recall_app/providers/auth_provider.dart';
import 'package:recall_app/providers/classroom_provider.dart';
import 'package:recall_app/providers/community_provider.dart';
import 'package:recall_app/providers/stats_provider.dart';
import 'package:recall_app/providers/study_set_provider.dart';
import 'package:recall_app/services/community_service.dart';

// ============================================================
// Shared dark text color used throughout the community page
// to guarantee readability on light backgrounds.
// ============================================================
const Color _darkText = Color(0xFF1A1A1A);
const Color _subtleText = Color(0xFF5C5C5C);

class CommunityScreen extends ConsumerStatefulWidget {
  final bool embedded;

  const CommunityScreen({super.key, this.embedded = false});

  @override
  ConsumerState<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends ConsumerState<CommunityScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearch(String value) {
    setState(() => _query = value.trim());
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _query = '';
      _isSearching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    final body = Column(
      children: [
        // Search bar
        Padding(
          padding: EdgeInsets.fromLTRB(16, widget.embedded ? 12 : 6, 16, 0),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE0E0E0)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(
                color: _darkText,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
              decoration: InputDecoration(
                hintText: l10n.communitySearchHint,
                hintStyle: const TextStyle(color: _subtleText),
                prefixIcon: const Icon(
                  Icons.search_rounded,
                  color: _subtleText,
                ),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(
                          Icons.close_rounded,
                          color: _subtleText,
                        ),
                        onPressed: _clearSearch,
                      ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
              ),
              onChanged: _onSearch,
              onTap: () => setState(() => _isSearching = true),
            ),
          ),
        ),
        // Tab bar
        if (!_isSearching || _query.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(3),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                dividerHeight: 0,
                labelColor: _darkText,
                unselectedLabelColor: _subtleText,
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 14,
                ),
                tabs: [
                  Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.explore_rounded, size: 18),
                        const SizedBox(width: 6),
                        Text(l10n.communityExplore),
                      ],
                    ),
                  ),
                  Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.groups_rounded, size: 18),
                        const SizedBox(width: 6),
                        Text(l10n.communityClassroom),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 10),
        // Content
        Expanded(
          child: _isSearching && _query.isNotEmpty
              ? _buildSearchResults(context, l10n)
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _ExploreTab(
                      query: _query,
                      onTagTap: (tag) {
                        _searchController.text = tag;
                        _onSearch(tag);
                        setState(() => _isSearching = true);
                      },
                    ),
                    const _ClassroomTab(),
                  ],
                ),
        ),
      ],
    );

    if (!widget.embedded) {
      return Scaffold(body: SafeArea(child: body));
    }
    return body;
  }

  Widget _buildSearchResults(BuildContext context, AppLocalizations l10n) {
    final studySets = ref.watch(studySetsProvider);
    final localResults = _searchLocal(studySets, _query);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        if (localResults.isNotEmpty) ...[
          _SectionHeader(
            icon: Icons.phone_android_rounded,
            title: l10n.communityLocalResults,
          ),
          const SizedBox(height: 8),
          ...localResults.map(
            (set) => _LocalSetCard(
              set: set,
              onTap: () => context.push('/study/${set.id}'),
            ),
          ),
          const SizedBox(height: 18),
        ],
        _SectionHeader(
          icon: Icons.public_rounded,
          title: l10n.communityPublicResults,
        ),
        const SizedBox(height: 8),
        _PublicSetsList(query: PublicSetsQuery(search: _query)),
      ],
    );
  }

  List<StudySet> _searchLocal(List<StudySet> sets, String query) {
    if (query.isEmpty) return [];
    final q = query.toLowerCase();
    return sets.where((set) {
      if (set.title.toLowerCase().contains(q)) return true;
      return set.cards.any(
        (c) =>
            c.term.toLowerCase().contains(q) ||
            c.definition.toLowerCase().contains(q) ||
            c.tags.any((t) => t.toLowerCase().contains(q)),
      );
    }).toList();
  }
}

// -- Explore Tab --

class _ExploreTab extends ConsumerStatefulWidget {
  final String query;
  final ValueChanged<String> onTagTap;

  const _ExploreTab({required this.query, required this.onTagTap});

  @override
  ConsumerState<_ExploreTab> createState() => _ExploreTabState();
}

class _ExploreTabState extends ConsumerState<_ExploreTab> {
  CommunitySortOption _sort = CommunitySortOption.trending;
  String _selectedCategory = '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final user = ref.watch(currentUserProvider);
    final localSets = ref.watch(studySetsProvider);
    final feedQuery = PublicSetsQuery(
      search: widget.query.isEmpty ? null : widget.query,
      sort: _sort,
      category: _selectedCategory,
    );
    final feedAsync = ref.watch(publicStudySetsProvider(feedQuery));

    return feedAsync.when(
      data: (feedSets) {
        final topTags = _extractTopTags(feedSets, fallbackLocalSets: localSets);
        final categories = _extractCategories(feedSets);
        final latestLocalSet = _latestLocalSet(localSets);
        final savedIds = ref.watch(communitySavedSetIdsProvider);
        final downloadedSets = _findDownloadedPublicSets(feedSets, localSets);
        final downloadedIds = {
          ...downloadedSets.map((set) => set.id),
          ...?ref.watch(communityDownloadedSetIdsProvider).value,
        };
        final recommendedSets = _buildRecommendedSets(
          publicSets: feedSets,
          localSets: localSets,
          currentUserId: user?.id,
        );
        final savedSets = feedSets
            .where((set) => savedIds.contains(set.id))
            .take(4)
            .toList();
        final myPublishedSets = user == null
            ? const <PublicStudySet>[]
            : feedSets.where((set) => set.userId == user.id).take(4).toList();
        final friendIds = ref.watch(communityFriendIdsProvider);
        final weeklyMinutes = _estimateWeeklyMinutes(
          ref.watch(allReviewLogsProvider),
        );
        final friendCandidates = _buildFriendCandidates(
          publicSets: feedSets,
          currentUserId: user?.id,
        );
        final leagueEntries = _buildLeagueEntries(
          weeklyMinutes: weeklyMinutes,
          selectedFriendIds: friendIds,
          candidates: friendCandidates,
          currentUserName: user?.email?.split('@').first ?? 'You',
        );

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(publicStudySetsProvider(feedQuery));
            if (user != null) {
              ref.invalidate(userPublicSetsProvider(user.id));
            }
            await Future<void>.delayed(const Duration(milliseconds: 250));
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
            children: [
              _CommunityHeroCard(
                title: l10n.communityTitle,
                primaryLabel: latestLocalSet == null ? '開始探索' : '延續最近學習',
                stats: [
                  _CommunityHeroStat(label: '公開集', value: '${feedSets.length}'),
                  _CommunityHeroStat(label: '已收藏', value: '${savedIds.length}'),
                  _CommunityHeroStat(
                    label: '已下載',
                    value: '${downloadedIds.length}',
                  ),
                ],
                onPrimaryTap: latestLocalSet == null
                    ? null
                    : () => context.push('/study/${latestLocalSet.id}'),
              ),
              const SizedBox(height: 20),
              if (categories.isNotEmpty) ...[
                _SectionHeader(
                  icon: Icons.category_rounded,
                  title: l10n.communityAllCategories,
                ),
                const SizedBox(height: 10),
                _CategoryFilterBar(
                  categories: categories,
                  selectedCategory: _selectedCategory,
                  onSelected: (category) {
                    setState(() => _selectedCategory = category);
                  },
                ),
                const SizedBox(height: 20),
              ],
              if (recommendedSets.isNotEmpty) ...[
                _SectionHeader(icon: Icons.auto_awesome_rounded, title: '為你推薦'),
                const SizedBox(height: 10),
                _PublicSetRail(
                  sets: recommendedSets.take(4).toList(),
                  emphasis: _PublicSetCardEmphasis.recommended,
                ),
                const SizedBox(height: 20),
              ],
              if (savedSets.isNotEmpty) ...[
                _SectionHeader(icon: Icons.bookmark_rounded, title: '收藏清單'),
                const SizedBox(height: 10),
                _PublicSetRail(
                  sets: savedSets,
                  emphasis: _PublicSetCardEmphasis.saved,
                ),
                const SizedBox(height: 20),
              ],
              if (myPublishedSets.isNotEmpty) ...[
                _SectionHeader(icon: Icons.cloud_done_rounded, title: '我的發布'),
                const SizedBox(height: 10),
                _PublicSetRail(
                  sets: myPublishedSets,
                  emphasis: _PublicSetCardEmphasis.owned,
                ),
                const SizedBox(height: 20),
              ],
              _SectionHeader(icon: Icons.emoji_events_rounded, title: '好友聯賽'),
              const SizedBox(height: 10),
              _FriendsLeagueCard(
                entries: leagueEntries,
                weeklyMinutes: weeklyMinutes,
                friendCount: friendIds.length,
                onManageFriends: friendCandidates.isEmpty
                    ? null
                    : () => _showFriendPickerSheet(
                        context,
                        friendCandidates,
                        friendIds,
                      ),
              ),
              const SizedBox(height: 20),
              _SectionHeader(
                icon: Icons.tag_rounded,
                title: l10n.communityPopularTags,
              ),
              const SizedBox(height: 10),
              _TagCloud(tags: topTags, onTagTap: widget.onTagTap),
              const SizedBox(height: 20),
              _SectionHeader(
                icon: Icons.trending_up_rounded,
                title: l10n.communityHotSets,
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _SortChip(
                      label: l10n.communitySortTrending,
                      icon: Icons.local_fire_department_rounded,
                      selected: _sort == CommunitySortOption.trending,
                      onTap: () =>
                          setState(() => _sort = CommunitySortOption.trending),
                    ),
                    const SizedBox(width: 8),
                    _SortChip(
                      label: l10n.communitySortNewest,
                      icon: Icons.schedule_rounded,
                      selected: _sort == CommunitySortOption.newest,
                      onTap: () =>
                          setState(() => _sort = CommunitySortOption.newest),
                    ),
                    const SizedBox(width: 8),
                    _SortChip(
                      label: l10n.communitySortMostDownloaded,
                      icon: Icons.download_rounded,
                      selected: _sort == CommunitySortOption.mostDownloaded,
                      onTap: () => setState(
                        () => _sort = CommunitySortOption.mostDownloaded,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _PublicSetsList(
                query: feedQuery,
                downloadedPublicSetIds: downloadedIds,
              ),
              if (user != null) ...[
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.green.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: AppTheme.green.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.cloud_upload_rounded,
                        color: AppTheme.green,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.communitySharePromptTitle,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                                color: _darkText,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              l10n.communitySharePromptBody,
                              style: const TextStyle(
                                fontSize: 13,
                                color: _subtleText,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      ),
      error: (_, __) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _CommunityHeroCard(
            title: l10n.communityTitle,
            primaryLabel: '稍後重試',
            onPrimaryTap: null,
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFE8E8E8)),
            ),
            child: Text(
              l10n.communityLoadError,
              style: const TextStyle(color: _darkText, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  StudySet? _latestLocalSet(List<StudySet> localSets) {
    if (localSets.isEmpty) return null;
    final sorted = [...localSets]
      ..sort((a, b) {
        final left = a.lastStudiedAt ?? a.updatedAt ?? a.createdAt;
        final right = b.lastStudiedAt ?? b.updatedAt ?? b.createdAt;
        return right.compareTo(left);
      });
    return sorted.first;
  }

  List<PublicStudySet> _findDownloadedPublicSets(
    List<PublicStudySet> publicSets,
    List<StudySet> localSets,
  ) {
    final service = ref.read(communityServiceProvider);
    return publicSets
        .where(
          (set) => service.findMatchingLocalStudySet(set, localSets) != null,
        )
        .toList();
  }

  List<PublicStudySet> _buildRecommendedSets({
    required List<PublicStudySet> publicSets,
    required List<StudySet> localSets,
    required String? currentUserId,
  }) {
    final service = ref.read(communityServiceProvider);
    final localKeywords = <String>{};
    for (final set in localSets) {
      localKeywords.addAll(_tokenize(set.title));
      localKeywords.addAll(_tokenize(set.description));
      for (final card in set.cards) {
        localKeywords.addAll(_tokenize(card.term));
        localKeywords.addAll(_tokenize(card.definition));
        localKeywords.addAll(card.tags.map((tag) => tag.trim().toLowerCase()));
      }
    }

    final scored = <({PublicStudySet set, int score})>[];
    for (final set in publicSets) {
      if (set.userId == currentUserId) continue;
      if (service.findMatchingLocalStudySet(set, localSets) != null) continue;
      final score = _recommendationScore(set, localKeywords);
      if (score > 0) {
        scored.add((set: set, score: score));
      }
    }
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byDownloads = b.set.downloadCount.compareTo(a.set.downloadCount);
      if (byDownloads != 0) return byDownloads;
      return b.set.createdAt.compareTo(a.set.createdAt);
    });
    return scored.map((item) => item.set).toList();
  }

  int _recommendationScore(PublicStudySet set, Set<String> localKeywords) {
    var score = 0;
    for (final token in _tokenize(set.title)) {
      if (localKeywords.contains(token)) score += 4;
    }
    for (final token in _tokenize(set.description)) {
      if (localKeywords.contains(token)) score += 1;
    }
    for (final card in set.cards) {
      for (final token in _tokenize(card.term)) {
        if (localKeywords.contains(token)) score += 2;
      }
      for (final token in _tokenize(card.definition)) {
        if (localKeywords.contains(token)) score += 1;
      }
    }
    for (final tag in set.tags.map((tag) => tag.trim().toLowerCase())) {
      if (localKeywords.contains(tag)) score += 6;
    }
    return score;
  }

  Set<String> _tokenize(String input) {
    return input
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'))
        .where((token) => token.length >= 2)
        .toSet();
  }

  List<String> _extractTopTags(
    List<PublicStudySet> publicSets, {
    required List<StudySet> fallbackLocalSets,
  }) {
    final counts = <String, int>{};
    for (final set in publicSets) {
      for (final tag in set.tags) {
        final normalized = tag.trim();
        if (normalized.isEmpty) continue;
        counts.update(normalized, (value) => value + 1, ifAbsent: () => 1);
      }
    }
    if (counts.isEmpty) {
      for (final set in fallbackLocalSets) {
        for (final card in set.cards) {
          for (final tag in card.tags) {
            final normalized = tag.trim();
            if (normalized.isEmpty) continue;
            counts.update(normalized, (value) => value + 1, ifAbsent: () => 1);
          }
        }
      }
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(10).map((entry) => entry.key).toList();
  }

  List<String> _extractCategories(List<PublicStudySet> publicSets) {
    final categories =
        publicSets
            .map((set) => set.category.trim())
            .where((category) => category.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return categories;
  }

  int _estimateWeeklyMinutes(Iterable<dynamic> reviewLogs) {
    final now = DateTime.now().toUtc();
    final from = now.subtract(const Duration(days: 7));
    var points = 0;
    for (final raw in reviewLogs) {
      final reviewedAt = raw.reviewedAt as DateTime;
      if (reviewedAt.isBefore(from)) continue;
      final reviewType = (raw.reviewType as String?) ?? 'srs';
      points += switch (reviewType) {
        'speaking' => 3,
        'matching' => 2,
        'quiz' => 2,
        _ => 1,
      };
    }
    return points * 2;
  }

  List<_FriendCandidate> _buildFriendCandidates({
    required List<PublicStudySet> publicSets,
    required String? currentUserId,
  }) {
    final grouped = <String, List<PublicStudySet>>{};
    for (final set in publicSets) {
      if (set.userId == currentUserId) continue;
      grouped.putIfAbsent(set.userId, () => <PublicStudySet>[]).add(set);
    }
    final candidates =
        grouped.entries.map((entry) {
          final sets = entry.value;
          final authorName = sets.first.authorName.trim().isEmpty
              ? 'Learner'
              : sets.first.authorName.trim();
          final publishedCount = sets.length;
          final totalDownloads = sets.fold<int>(
            0,
            (sum, set) => sum + set.downloadCount,
          );
          final cardVolume = sets.fold<int>(
            0,
            (sum, set) => sum + set.cards.length,
          );
          final estimatedMinutes =
              18 +
              (publishedCount * 9) +
              (totalDownloads ~/ 2) +
              (cardVolume ~/ 3);
          return _FriendCandidate(
            userId: entry.key,
            displayName: authorName,
            publishedCount: publishedCount,
            totalDownloads: totalDownloads,
            estimatedWeeklyMinutes: estimatedMinutes,
          );
        }).toList()..sort(
          (a, b) =>
              b.estimatedWeeklyMinutes.compareTo(a.estimatedWeeklyMinutes),
        );
    return candidates;
  }

  List<_LeagueEntry> _buildLeagueEntries({
    required int weeklyMinutes,
    required List<String> selectedFriendIds,
    required List<_FriendCandidate> candidates,
    required String currentUserName,
  }) {
    final entries = <_LeagueEntry>[
      _LeagueEntry(
        userId: 'me',
        displayName: currentUserName,
        weeklyMinutes: weeklyMinutes,
        isCurrentUser: true,
      ),
    ];
    final candidateMap = {
      for (final candidate in candidates) candidate.userId: candidate,
    };
    for (final friendId in selectedFriendIds) {
      final candidate = candidateMap[friendId];
      if (candidate == null) continue;
      entries.add(
        _LeagueEntry(
          userId: candidate.userId,
          displayName: candidate.displayName,
          weeklyMinutes: candidate.estimatedWeeklyMinutes,
        ),
      );
    }
    entries.sort((a, b) => b.weeklyMinutes.compareTo(a.weeklyMinutes));
    return entries;
  }

  void _showFriendPickerSheet(
    BuildContext context,
    List<_FriendCandidate> candidates,
    List<String> friendIds,
  ) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD6D1C8),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(
                        '加好友',
                        style: GoogleFonts.notoSerifTc(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: _darkText,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '先做本地收藏，之後可接真實好友系統',
                        style: const TextStyle(
                          fontSize: 12,
                          color: _subtleText,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: candidates.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final candidate = candidates[index];
                        final isFriend = friendIds.contains(candidate.userId);
                        return _FriendCandidateTile(
                          candidate: candidate,
                          isFriend: isFriend,
                          onToggle: () async {
                            final notifier = ref.read(
                              communityFriendIdsProvider.notifier,
                            );
                            if (isFriend) {
                              await notifier.remove(candidate.userId);
                            } else {
                              await notifier.add(candidate.userId);
                            }
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CommunityHeroCard extends StatelessWidget {
  const _CommunityHeroCard({
    required this.title,
    required this.primaryLabel,
    required this.onPrimaryTap,
    this.stats = const [],
  });

  final String title;
  final String primaryLabel;
  final VoidCallback? onPrimaryTap;
  final List<_CommunityHeroStat> stats;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFF5F1E8),
            AppTheme.gold.withValues(alpha: 0.32),
            AppTheme.cyan.withValues(alpha: 0.18),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE6E0D5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.notoSerifTc(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: _darkText,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(onPressed: onPrimaryTap, child: Text(primaryLabel)),
            ],
          ),
          if (stats.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(
              children: stats
                  .map(
                    (stat) => Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: stat == stats.last ? 0 : 8,
                        ),
                        child: stat,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _CommunityHeroStat extends StatelessWidget {
  const _CommunityHeroStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: _darkText,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: _subtleText,
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryFilterBar extends StatelessWidget {
  const _CategoryFilterBar({
    required this.categories,
    required this.selectedCategory,
    required this.onSelected,
  });

  final List<String> categories;
  final String selectedCategory;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _CategoryChip(
            label: AppLocalizations.of(context).communityAllCategories,
            selected: selectedCategory.isEmpty,
            onTap: () => onSelected(''),
          ),
          const SizedBox(width: 8),
          ...categories.map(
            (category) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _CategoryChip(
                label: category,
                selected: selectedCategory == category,
                onTap: () => onSelected(category),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.indigo.withValues(alpha: 0.12)
              : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? AppTheme.indigo.withValues(alpha: 0.42)
                : const Color(0xFFE2DDD2),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: selected ? AppTheme.indigo : _darkText,
          ),
        ),
      ),
    );
  }
}

class _PublicSetRail extends StatelessWidget {
  const _PublicSetRail({required this.sets, required this.emphasis});

  final List<PublicStudySet> sets;
  final _PublicSetCardEmphasis emphasis;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: sets
          .map((set) => _PublicSetCard(publicSet: set, emphasis: emphasis))
          .toList(),
    );
  }
}

class _TagCloud extends StatelessWidget {
  const _TagCloud({required this.tags, required this.onTagTap});

  final List<String> tags;
  final ValueChanged<String> onTagTap;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFFAF8F4),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE8E2D7)),
        ),
        child: const Text(
          '還沒有可用標籤，先發布或下載幾套內容會更完整。',
          style: TextStyle(fontSize: 13, color: _subtleText),
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: tags
          .map(
            (tag) => InkWell(
              onTap: () => onTagTap(tag),
              borderRadius: BorderRadius.circular(999),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0xFFE2DDD2)),
                ),
                child: Text(
                  '# $tag',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _darkText,
                  ),
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _FriendCandidate {
  const _FriendCandidate({
    required this.userId,
    required this.displayName,
    required this.publishedCount,
    required this.totalDownloads,
    required this.estimatedWeeklyMinutes,
  });

  final String userId;
  final String displayName;
  final int publishedCount;
  final int totalDownloads;
  final int estimatedWeeklyMinutes;
}

class _LeagueEntry {
  const _LeagueEntry({
    required this.userId,
    required this.displayName,
    required this.weeklyMinutes,
    this.isCurrentUser = false,
  });

  final String userId;
  final String displayName;
  final int weeklyMinutes;
  final bool isCurrentUser;
}

class _FriendsLeagueCard extends StatelessWidget {
  const _FriendsLeagueCard({
    required this.entries,
    required this.weeklyMinutes,
    required this.friendCount,
    this.onManageFriends,
  });

  final List<_LeagueEntry> entries;
  final int weeklyMinutes;
  final int friendCount;
  final VoidCallback? onManageFriends;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE7E1D7)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$weeklyMinutes 分鐘 / 本週',
                      style: GoogleFonts.notoSerifTc(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: _darkText,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      friendCount == 0
                          ? '先加好友，才能看到像 Duolingo 那樣的聯賽比較。'
                          : '你目前和 $friendCount 位好友一起進入本週排行榜。',
                      style: const TextStyle(fontSize: 13, color: _subtleText),
                    ),
                  ],
                ),
              ),
              if (onManageFriends != null)
                FilledButton.icon(
                  onPressed: onManageFriends,
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                  label: const Text('加好友'),
                ),
            ],
          ),
          const SizedBox(height: 14),
          ...entries.take(5).toList().asMap().entries.map((entry) {
            final rank = entry.key + 1;
            final item = entry.value;
            return Container(
              margin: EdgeInsets.only(
                bottom: rank == entries.take(5).length ? 0 : 8,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: item.isCurrentUser
                    ? AppTheme.indigo.withValues(alpha: 0.10)
                    : const Color(0xFFF9F7F2),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: rank == 1
                          ? AppTheme.gold.withValues(alpha: 0.8)
                          : Colors.white,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        '$rank',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: _darkText,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item.displayName,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: item.isCurrentUser
                            ? FontWeight.w800
                            : FontWeight.w600,
                        color: _darkText,
                      ),
                    ),
                  ),
                  Text(
                    '${item.weeklyMinutes} min',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: _subtleText,
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 10),
          const Text(
            '註：目前只有你的時間來自真實學習紀錄，好友為社群活躍度估算值，後續可接真實好友後端。',
            style: TextStyle(fontSize: 11, color: _subtleText, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _FriendCandidateTile extends StatelessWidget {
  const _FriendCandidateTile({
    required this.candidate,
    required this.isFriend,
    required this.onToggle,
  });

  final _FriendCandidate candidate;
  final bool isFriend;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F7F2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE8E2D7)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppTheme.indigo.withValues(alpha: 0.14),
            child: Text(
              candidate.displayName.isEmpty
                  ? '?'
                  : candidate.displayName.substring(0, 1).toUpperCase(),
              style: const TextStyle(
                color: AppTheme.indigo,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  candidate.displayName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: _darkText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${candidate.publishedCount} published · ${candidate.totalDownloads} downloads · ${candidate.estimatedWeeklyMinutes} min beta',
                  style: const TextStyle(fontSize: 12, color: _subtleText),
                ),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: onToggle,
            child: Text(isFriend ? '已加入' : '加入'),
          ),
        ],
      ),
    );
  }
}

// -- Sort Chip --

class _SortChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _SortChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.indigo.withValues(alpha: 0.1)
              : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AppTheme.indigo.withValues(alpha: 0.4)
                : const Color(0xFFDDDDDD),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? AppTheme.indigo : _subtleText,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                fontSize: 13,
                color: selected ? AppTheme.indigo : _darkText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -- Classroom Tab (embedded) --

class _ClassroomTab extends ConsumerStatefulWidget {
  const _ClassroomTab();

  @override
  ConsumerState<_ClassroomTab> createState() => _ClassroomTabState();
}

class _ClassroomTabState extends ConsumerState<_ClassroomTab> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final user = ref.watch(currentUserProvider);

    if (user == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE8E8E8)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_rounded, size: 48, color: _subtleText),
                const SizedBox(height: 16),
                Text(
                  l10n.communityLoginRequired,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: _darkText,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.communityLoginHint,
                  style: const TextStyle(fontSize: 13, color: _subtleText),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: () => context.push('/login'),
                  child: Text(l10n.logIn),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Embedded classroom list
    final roleAsync = ref.watch(myRoleProvider);
    final classesAsync = ref.watch(myClassesProvider);

    return classesAsync.when(
      data: (classes) {
        final role = roleAsync.valueOrNull ?? 'student';
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(myRoleProvider);
            ref.invalidate(myClassesProvider);
            await Future<void>.delayed(const Duration(milliseconds: 250));
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              // Role + action buttons
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFE8E8E8)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.communityClassroomTitle,
                      style: GoogleFonts.notoSerifTc(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: _darkText,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.communityClassroomHint,
                      style: const TextStyle(fontSize: 13, color: _subtleText),
                    ),
                    const SizedBox(height: 12),
                    // Role toggle
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment<String>(
                          value: 'teacher',
                          icon: Icon(Icons.school_rounded, size: 16),
                          label: Text('\u8001\u5E2B'),
                        ),
                        ButtonSegment<String>(
                          value: 'student',
                          icon: Icon(Icons.person_rounded, size: 16),
                          label: Text('\u5B78\u751F'),
                        ),
                      ],
                      selected: {role},
                      onSelectionChanged: (value) async {
                        await ref
                            .read(classroomServiceProvider)
                            .updateMyRole(value.first);
                        ref.invalidate(myRoleProvider);
                        ref.invalidate(myClassesProvider);
                      },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () {
                              if (role == 'teacher') {
                                _showCreateClassDialog(context, ref);
                              } else {
                                _showJoinClassDialog(context, ref);
                              }
                            },
                            icon: Icon(
                              role == 'teacher'
                                  ? Icons.add_circle_outline_rounded
                                  : Icons.input_rounded,
                              size: 18,
                            ),
                            label: Text(
                              role == 'teacher'
                                  ? '\u5EFA\u7ACB\u73ED\u7D1A'
                                  : '\u52A0\u5165\u73ED\u7D1A',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Class list
              if (classes.isEmpty)
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFAFAFA),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE8E8E8)),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        role == 'teacher'
                            ? Icons.school_rounded
                            : Icons.meeting_room_rounded,
                        size: 36,
                        color: _subtleText,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        role == 'teacher'
                            ? '\u9084\u6C92\u6709\u5EFA\u7ACB\u4EFB\u4F55\u73ED\u7D1A'
                            : '\u4F60\u9084\u6C92\u6709\u52A0\u5165\u4EFB\u4F55\u73ED\u7D1A',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: _darkText,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              else
                ...classes.map(
                  (classroom) =>
                      _EmbeddedClassCard(classroom: classroom, role: role),
                ),
            ],
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 40, color: _subtleText),
              const SizedBox(height: 12),
              Text(
                l10n.communityLoadError,
                style: const TextStyle(
                  color: _darkText,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                '請確認雲端資料庫已設定',
                style: const TextStyle(color: _subtleText, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCreateClassDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final nameController = TextEditingController();
    final subjectController = TextEditingController();
    final gradeController = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('\u5EFA\u7ACB\u73ED\u7D1A'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '\u73ED\u7D1A\u540D\u7A31',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: subjectController,
                decoration: const InputDecoration(labelText: '\u79D1\u76EE'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: gradeController,
                decoration: const InputDecoration(labelText: '\u5E74\u7D1A'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('\u53D6\u6D88'),
          ),
          FilledButton(
            onPressed: () async {
              if (nameController.text.trim().isEmpty) return;
              try {
                await ref
                    .read(classroomServiceProvider)
                    .createClass(
                      name: nameController.text,
                      subject: subjectController.text,
                      grade: gradeController.text,
                    );
                if (ctx.mounted) Navigator.of(ctx).pop(true);
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      '\u5EFA\u7ACB\u73ED\u7D1A\u5931\u6557\uFF1A$e',
                    ),
                  ),
                );
              }
            },
            child: const Text('\u5EFA\u7ACB'),
          ),
        ],
      ),
    );
    nameController.dispose();
    subjectController.dispose();
    gradeController.dispose();
    if (created == true) {
      ref.invalidate(myClassesProvider);
    }
  }

  Future<void> _showJoinClassDialog(BuildContext context, WidgetRef ref) async {
    final codeController = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);

    final joined = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('\u52A0\u5165\u73ED\u7D1A'),
        content: TextField(
          controller: codeController,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: '\u9080\u8ACB\u78BC',
            hintText: '\u4F8B\u5982\uFF1AA1B2C3D4',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('\u53D6\u6D88'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                await ref
                    .read(classroomServiceProvider)
                    .joinClassByInviteCode(codeController.text);
                if (ctx.mounted) Navigator.of(ctx).pop(true);
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      '\u52A0\u5165\u73ED\u7D1A\u5931\u6557\uFF1A$e',
                    ),
                  ),
                );
              }
            },
            child: const Text('\u52A0\u5165'),
          ),
        ],
      ),
    );
    codeController.dispose();
    if (joined == true) {
      ref.invalidate(myClassesProvider);
    }
  }
}

// -- Embedded Class Card --

class _EmbeddedClassCard extends StatelessWidget {
  final Classroom classroom;
  final String role;

  const _EmbeddedClassCard({required this.classroom, required this.role});

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      classroom.subject,
      classroom.grade,
    ].where((s) => s.trim().isNotEmpty).join(' \u00B7 ');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE8E8E8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: InkWell(
        onTap: () => context.push('/classes/${classroom.id}'),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: AppTheme.indigo.withValues(alpha: 0.08),
                ),
                child: Icon(
                  role == 'teacher'
                      ? Icons.cast_for_education_rounded
                      : Icons.collections_bookmark_rounded,
                  color: AppTheme.indigo,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            classroom.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.notoSerifTc(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: _darkText,
                            ),
                          ),
                        ),
                        if (classroom.isArchived)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.red.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '\u5DF2\u5C01\u5B58',
                              style: TextStyle(
                                color: AppTheme.red,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle.isEmpty
                          ? '\u5C1A\u672A\u8A2D\u5B9A\u79D1\u76EE\u6216\u5E74\u7D1A'
                          : subtitle,
                      style: const TextStyle(fontSize: 13, color: _subtleText),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: _subtleText),
            ],
          ),
        ),
      ),
    );
  }
}

// -- Public Sets List --

enum _PublicSetCardEmphasis { normal, recommended, saved, owned, downloaded }

class _PublicSetsList extends ConsumerWidget {
  final PublicSetsQuery query;
  final Set<String> downloadedPublicSetIds;

  const _PublicSetsList({
    required this.query,
    this.downloadedPublicSetIds = const {},
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final setsAsync = ref.watch(publicStudySetsProvider(query));

    return setsAsync.when(
      data: (sets) {
        if (sets.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFFFAFAFA),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE8E8E8)),
            ),
            child: Row(
              children: [
                const Icon(Icons.search_off_rounded, color: _subtleText),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.communityNoPublicSets,
                    style: const TextStyle(color: _darkText, fontSize: 14),
                  ),
                ),
              ],
            ),
          );
        }

        return Column(
          children: sets
              .map(
                (ps) => _PublicSetCard(
                  publicSet: ps,
                  emphasis: downloadedPublicSetIds.contains(ps.id)
                      ? _PublicSetCardEmphasis.downloaded
                      : _PublicSetCardEmphasis.normal,
                ),
              )
              .toList(),
        );
      },
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      ),
      error: (e, _) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFA),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          l10n.communityLoadError,
          style: const TextStyle(color: _darkText),
        ),
      ),
    );
  }
}

// -- Public Set Card --

class _PublicSetCard extends ConsumerWidget {
  final PublicStudySet publicSet;
  final _PublicSetCardEmphasis emphasis;

  const _PublicSetCard({
    required this.publicSet,
    this.emphasis = _PublicSetCardEmphasis.normal,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSaved = ref.watch(
      communitySavedSetIdsProvider.select((ids) => ids.contains(publicSet.id)),
    );
    final isLiked = ref.watch(
      communityLikedSetIdsProvider.select((ids) => ids.contains(publicSet.id)),
    );
    final isLoggedIn = ref.watch(currentUserProvider) != null;
    final badge = _badge(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE8E8E8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: InkWell(
        onTap: () => showPreview(context, ref),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppTheme.indigo.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    '${publicSet.cards.length}',
                    style: GoogleFonts.notoSerifTc(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.indigo,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      publicSet.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.notoSerifTc(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: _darkText,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        // Tappable author name → profile
                        GestureDetector(
                          onTap: () =>
                              context.push('/profile/${publicSet.userId}'),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.person_outline_rounded,
                                size: 14,
                                color: AppTheme.indigo,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                publicSet.authorName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: AppTheme.indigo,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Icon(
                          Icons.download_rounded,
                          size: 14,
                          color: _subtleText,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '${publicSet.downloadCount}',
                          style: const TextStyle(
                            color: _subtleText,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(
                          Icons.favorite_rounded,
                          size: 14,
                          color: _subtleText,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '${publicSet.likeCount}',
                          style: const TextStyle(
                            color: _subtleText,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    // Tags inline
                    if (publicSet.tags.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: publicSet.tags
                            .take(3)
                            .map(
                              (t) => Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF0F0F0),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  t,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: _darkText,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
              if (badge != null) ...[const SizedBox(width: 8), badge],
              if (_isOwn(ref) && emphasis != _PublicSetCardEmphasis.owned)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.green.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    AppLocalizations.of(context).communityMyPublished,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.green,
                    ),
                  ),
                )
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isLoggedIn)
                      IconButton(
                        tooltip: isLiked ? '取消讚' : '按讚',
                        visualDensity: VisualDensity.compact,
                        onPressed: () async {
                          await ref
                              .read(communityLikedSetIdsProvider.notifier)
                              .toggle(publicSet.id);
                          ref.invalidate(publicStudySetsProvider);
                        },
                        icon: Icon(
                          isLiked
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: isLiked ? AppTheme.red : _subtleText,
                        ),
                      ),
                    IconButton(
                      tooltip: isSaved ? '取消收藏' : '收藏',
                      visualDensity: VisualDensity.compact,
                      onPressed: () async {
                        await ref
                            .read(communitySavedSetIdsProvider.notifier)
                            .toggle(publicSet.id);
                        ref.invalidate(publicStudySetsProvider);
                      },
                      icon: Icon(
                        isSaved
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded,
                        color: isSaved ? AppTheme.gold : _subtleText,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isOwn(WidgetRef ref) {
    final user = ref.read(currentUserProvider);
    return user != null && user.id == publicSet.userId;
  }

  Widget? _badge(BuildContext context) {
    final (label, color) = switch (emphasis) {
      _PublicSetCardEmphasis.recommended => ('推薦', AppTheme.indigo),
      _PublicSetCardEmphasis.saved => ('收藏', AppTheme.gold),
      _PublicSetCardEmphasis.downloaded => ('已下載', AppTheme.green),
      _PublicSetCardEmphasis.owned => (
        AppLocalizations.of(context).communityMyPublished,
        AppTheme.green,
      ),
      _PublicSetCardEmphasis.normal => ('', Colors.transparent),
    };
    if (label.isEmpty) return null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }

  void showPreview(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final user = ref.read(currentUserProvider);
    final isSaved = ref
        .read(communitySavedSetIdsProvider)
        .contains(publicSet.id);
    final isLiked = ref
        .read(communityLikedSetIdsProvider)
        .contains(publicSet.id);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // Handle
              Container(
                margin: const EdgeInsets.only(top: 10),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFCCCCCC),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            publicSet.title,
                            style: GoogleFonts.notoSerifTc(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: _darkText,
                            ),
                          ),
                        ),
                        // Report button
                        IconButton(
                          onPressed: () async {
                            await ref
                                .read(communitySavedSetIdsProvider.notifier)
                                .toggle(publicSet.id);
                            ref.invalidate(publicStudySetsProvider);
                          },
                          icon: Icon(
                            isSaved
                                ? Icons.bookmark_rounded
                                : Icons.bookmark_border_rounded,
                          ),
                          tooltip: isSaved ? '取消收藏' : '收藏',
                          color: isSaved ? AppTheme.gold : _subtleText,
                        ),
                        if (user != null && user.id != publicSet.userId)
                          IconButton(
                            onPressed: () =>
                                _showReportDialog(context, ref, l10n),
                            icon: const Icon(Icons.flag_outlined, size: 20),
                            tooltip: l10n.communityReport,
                            color: _subtleText,
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () {
                            Navigator.of(context).pop();
                            context.push('/profile/${publicSet.userId}');
                          },
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.person_outline_rounded,
                                size: 16,
                                color: AppTheme.indigo,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                publicSet.authorName,
                                style: TextStyle(
                                  color: AppTheme.indigo,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        const Icon(
                          Icons.style_rounded,
                          size: 16,
                          color: _subtleText,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          l10n.nCards(publicSet.cards.length),
                          style: const TextStyle(
                            fontSize: 13,
                            color: _subtleText,
                          ),
                        ),
                        const SizedBox(width: 14),
                        const Icon(
                          Icons.favorite_rounded,
                          size: 16,
                          color: _subtleText,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${publicSet.likeCount}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: _subtleText,
                          ),
                        ),
                        const SizedBox(width: 14),
                        const Icon(
                          Icons.bookmark_rounded,
                          size: 16,
                          color: _subtleText,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${publicSet.saveCount}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: _subtleText,
                          ),
                        ),
                        const SizedBox(width: 14),
                        const Icon(
                          Icons.download_rounded,
                          size: 16,
                          color: _subtleText,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${publicSet.downloadCount}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: _subtleText,
                          ),
                        ),
                      ],
                    ),
                    if (publicSet.description.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        publicSet.description,
                        style: const TextStyle(fontSize: 14, color: _darkText),
                      ),
                    ],
                    if (publicSet.tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: publicSet.tags
                            .map(
                              (t) => Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF0F0F0),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '# $t',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: _darkText,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(),
              // Card preview list
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  itemCount: publicSet.cards.length,
                  itemBuilder: (context, index) {
                    final card = publicSet.cards[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8F8F8),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFEEEEEE)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            card.term,
                            style: GoogleFonts.notoSerifTc(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: _darkText,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            card.definition,
                            style: const TextStyle(
                              fontSize: 14,
                              color: _subtleText,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              // Action buttons
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Column(
                  children: [
                    if (user != null && user.id != publicSet.userId) ...[
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await ref
                                .read(communityLikedSetIdsProvider.notifier)
                                .toggle(publicSet.id);
                            ref.invalidate(publicStudySetsProvider);
                            if (!context.mounted) return;
                            Navigator.of(context).pop();
                          },
                          icon: Icon(
                            isLiked
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                          ),
                          label: Text(isLiked ? '取消讚' : '按讚'),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (_isOwn(ref)) ...[
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => _unpublishSet(context, ref, l10n),
                          icon: const Icon(Icons.cloud_off_rounded),
                          label: Text(l10n.communityUnpublish),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.red,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            side: BorderSide(
                              color: AppTheme.red.withValues(alpha: 0.3),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => _downloadSet(context, ref, l10n),
                        icon: const Icon(Icons.download_rounded),
                        label: Text(l10n.communityDownload),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showReportDialog(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) {
    final reasons = [
      (l10n.communityReportInappropriate, 'inappropriate'),
      (l10n.communityReportSpam, 'spam'),
      (l10n.communityReportCopyright, 'copyright'),
      (l10n.communityReportOther, 'other'),
    ];

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.communityReportTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.communityReportHint,
              style: const TextStyle(color: _darkText),
            ),
            const SizedBox(height: 12),
            ...reasons.map(
              (r) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(r.$1, style: const TextStyle(color: _darkText)),
                leading: const Icon(Icons.radio_button_unchecked_rounded),
                onTap: () => _submitReport(ctx, ref, l10n, r.$2),
                dense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancel),
          ),
        ],
      ),
    );
  }

  Future<void> _submitReport(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    String reason,
  ) async {
    Navigator.of(context).pop(); // Close report dialog
    try {
      await ref
          .read(communityServiceProvider)
          .reportPublicSet(publicSetId: publicSet.id, reason: reason);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.communityReportSubmitted),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  Future<void> _downloadSet(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) async {
    final service = ref.read(communityServiceProvider);
    final existingSet = service.findMatchingLocalStudySet(
      publicSet,
      ref.read(studySetsProvider),
    );

    if (existingSet != null) {
      if (context.mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${publicSet.title} is already in your library.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        context.push('/study/${existingSet.id}');
      }
      return;
    }

    final localSet = service.toLocalStudySet(publicSet);

    ref.read(studySetsProvider.notifier).add(localSet);
    await service.incrementDownloadCount(publicSet.id);
    ref.invalidate(communityDownloadedSetIdsProvider);
    ref.invalidate(publicStudySetsProvider);

    if (context.mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.communityDownloaded(publicSet.title)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _unpublishSet(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) async {
    try {
      await ref
          .read(communityServiceProvider)
          .unpublishStudySet(publicSet.studySetId);
      ref.invalidate(publicStudySetsProvider);
      if (context.mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.communityUnpublished),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), behavior: SnackBarBehavior.floating),
        );
      }
    }
  }
}

// -- Local Set Card --

class _LocalSetCard extends StatelessWidget {
  final StudySet set;
  final VoidCallback onTap;

  const _LocalSetCard({required this.set, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE8E8E8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppTheme.indigo.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.folder_rounded, color: AppTheme.indigo),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      set.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.notoSerifTc(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: _darkText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${set.cards.length} cards',
                      style: const TextStyle(fontSize: 13, color: _subtleText),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: _subtleText),
            ],
          ),
        ),
      ),
    );
  }
}

// -- Section Header --

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;

  const _SectionHeader({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 4,
              height: 18,
              decoration: BoxDecoration(
                color: AppTheme.indigo,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(width: 8),
            Icon(icon, size: 18, color: AppTheme.indigo),
            const SizedBox(width: 6),
            Text(
              title,
              style: GoogleFonts.notoSerifTc(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: _darkText,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
