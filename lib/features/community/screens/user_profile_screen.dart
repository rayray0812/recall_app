import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/core/theme/app_theme.dart';
import 'package:recall_app/core/widgets/adaptive_glass_card.dart';
import 'package:recall_app/providers/community_provider.dart';
import 'package:recall_app/providers/study_set_provider.dart';
import 'package:recall_app/services/community_service.dart';

class UserProfileScreen extends ConsumerWidget {
  final String userId;

  const UserProfileScreen({super.key, required this.userId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final profileAsync = ref.watch(userProfileProvider(userId));
    final setsAsync = ref.watch(userPublicSetsProvider(userId));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.profileTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // Profile header
          profileAsync.when(
            data: (profile) => _ProfileHeader(profile: profile),
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
            error: (_, __) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 20),
          // Published sets
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
              Icon(
                Icons.library_books_rounded,
                size: 18,
                color: AppTheme.indigo,
              ),
              const SizedBox(width: 6),
              Text(
                l10n.profilePublishedSets,
                style: GoogleFonts.notoSerifTc(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          setsAsync.when(
            data: (sets) {
              if (sets.isEmpty) {
                return AdaptiveGlassCard(
                  borderRadius: 14,
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Icon(
                        Icons.inbox_rounded,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(width: 10),
                      Text(l10n.profileNoSets),
                    ],
                  ),
                );
              }
              return Column(
                children: sets
                    .map(
                      (ps) => _ProfileSetCard(
                        publicSet: ps,
                        onDownload: () => _downloadSet(context, ref, ps, l10n),
                      ),
                    )
                    .toList(),
              );
            },
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
            error: (_, __) => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadSet(
    BuildContext context,
    WidgetRef ref,
    PublicStudySet publicSet,
    AppLocalizations l10n,
  ) async {
    final service = ref.read(communityServiceProvider);
    final existingSet = service.findMatchingLocalStudySet(
      publicSet,
      ref.read(studySetsProvider),
    );
    if (existingSet != null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${publicSet.title} is already in your library.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    final localSet = service.toLocalStudySet(publicSet);
    ref.read(studySetsProvider.notifier).add(localSet);
    await service.incrementDownloadCount(publicSet.id);
    ref.invalidate(communityDownloadedSetIdsProvider);
    ref.invalidate(publicStudySetsProvider);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.communityDownloaded(publicSet.title)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

class _ProfileHeader extends StatelessWidget {
  final UserPublicProfile profile;

  const _ProfileHeader({required this.profile});

  @override
  Widget build(BuildContext context) {
    return AdaptiveGlassCard(
      borderRadius: 22,
      fillColor: Colors.white.withValues(alpha: 0.82),
      borderColor: Colors.white.withValues(alpha: 0.44),
      elevation: 1.4,
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Avatar
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.indigo.withValues(alpha: 0.12),
            ),
            child: Center(
              child: Text(
                profile.displayName.isNotEmpty
                    ? profile.displayName[0].toUpperCase()
                    : '?',
                style: GoogleFonts.notoSerifTc(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.indigo,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            profile.displayName.isNotEmpty ? profile.displayName : 'Anonymous',
            style: GoogleFonts.notoSerifTc(
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          // Stats row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _StatPill(
                icon: Icons.publish_rounded,
                value: '${profile.publishedCount}',
                label: AppLocalizations.of(context).profilePublishedSets,
              ),
              const SizedBox(width: 16),
              _StatPill(
                icon: Icons.download_rounded,
                value: '${profile.totalDownloads}',
                label: AppLocalizations.of(context).profileTotalDownloads,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _StatPill({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.indigo.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: AppTheme.indigo),
              const SizedBox(width: 6),
              Text(
                value,
                style: GoogleFonts.notoSerifTc(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.indigo,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.outline,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileSetCard extends StatelessWidget {
  final PublicStudySet publicSet;
  final VoidCallback onDownload;

  const _ProfileSetCard({required this.publicSet, required this.onDownload});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: AdaptiveGlassCard(
        borderRadius: 16,
        fillColor: Colors.white.withValues(alpha: 0.82),
        borderColor: Colors.white.withValues(alpha: 0.42),
        elevation: 1.2,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppTheme.cyan.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(13),
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
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(
                          Icons.download_rounded,
                          size: 14,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '${publicSet.downloadCount}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onDownload,
                icon: const Icon(Icons.download_rounded),
                color: AppTheme.indigo,
                tooltip: AppLocalizations.of(context).communityDownload,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
