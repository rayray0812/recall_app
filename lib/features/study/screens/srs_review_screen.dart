import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:recall_app/core/constants/study_constants.dart';
import 'package:recall_app/core/services/study_haptics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/core/theme/app_theme.dart';
import 'package:recall_app/core/widgets/app_back_button.dart';
import 'package:recall_app/features/study/services/voice_playback_service.dart';
import 'package:recall_app/features/study/widgets/combo_indicator.dart';
import 'package:recall_app/features/study/widgets/completion_celebrate_overlay.dart';
import 'package:recall_app/features/study/widgets/mnemonic_button.dart';
import 'package:recall_app/features/study/widgets/rating_buttons.dart';
import 'package:recall_app/features/study/widgets/review_hint_button.dart';
import 'package:recall_app/features/study/widgets/xp_toast.dart';
import 'package:recall_app/providers/session_xp_provider.dart';
import 'package:recall_app/features/study/widgets/rounded_progress_bar.dart';
import 'package:recall_app/models/card_progress.dart';
import 'package:recall_app/models/flashcard.dart';
import 'package:recall_app/providers/fsrs_provider.dart';
import 'package:recall_app/providers/stats_provider.dart';
import 'package:recall_app/providers/study_set_provider.dart';
import 'package:recall_app/providers/widget_provider.dart';

/// SRS review screen: show card front -> tap to flip -> rate Again/Hard/Good/Easy.
class SrsReviewScreen extends ConsumerStatefulWidget {
  final String? setId;
  final List<String>? filterTags;
  final int? maxCards;
  final bool challengeMode;
  final int? challengeTarget;
  final List<String>? revengeCardIds;

  const SrsReviewScreen({
    super.key,
    this.setId,
    this.filterTags,
    this.maxCards,
    this.challengeMode = false,
    this.challengeTarget,
    this.revengeCardIds,
  });

  @override
  ConsumerState<SrsReviewScreen> createState() => _SrsReviewScreenState();
}

class _SrsReviewScreenState extends ConsumerState<SrsReviewScreen>
    with TickerProviderStateMixin {
  late AnimationController _flipController;
  late Animation<double> _flipAnimation;
  bool _isFlipped = false;
  bool _isSubmittingRating = false;
  int? _lastRating;

  List<_ReviewItem> _queue = [];
  int _currentIndex = 0;
  bool _isQueueLoading = true;
  String? _queueError;
  int _againCount = 0;
  int _hardCount = 0;
  int _goodCount = 0;
  int _easyCount = 0;

  late final VoicePlaybackService _voice;
  DateTime? _lastSpeakTapAt;

  // Celebration overlay
  AnimationController? _celebrateController;
  bool _showCelebration = false;
  final _xpToastKey = GlobalKey<XpToastOverlayState>();

  @override
  void initState() {
    super.initState();
    _flipController = AnimationController(
      duration: StudyConstants.flipDuration,
      vsync: this,
    );
    _flipAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _flipController, curve: StudyConstants.flipCurve),
    );

    _voice = VoicePlaybackService();
    _voice.init();

    WidgetsBinding.instance.addPostFrameCallback((_) => _buildQueue());
  }

  Future<void> _buildQueue() async {
    if (mounted) {
      setState(() {
        _isQueueLoading = true;
        _queueError = null;
      });
    }

    try {
      final localStorage = ref.read(localStorageServiceProvider);
      final studySets = ref.read(studySetsProvider);
      final now = DateTime.now().toUtc();
      final List<_ReviewItem> items = [];
      final allProgress = localStorage.getAllCardProgress();
      final progressByCardId = <String, CardProgress>{
        for (final p in allProgress) p.cardId: p,
      };

      if (widget.revengeCardIds != null && widget.revengeCardIds!.isNotEmpty) {
        final cardsById = <String, Flashcard>{};
        for (final set in studySets) {
          for (final card in set.cards) {
            cardsById[card.id] = card;
          }
        }
        for (final cardId in widget.revengeCardIds!) {
          final card = cardsById[cardId];
          if (card == null) continue;
          final progress = progressByCardId[cardId];
          if (progress == null) continue;
          items.add(_ReviewItem(card: card, progress: progress));
        }
      } else if (widget.setId != null) {
        final studySet = localStorage.getStudySet(widget.setId!);
        final setProgress = localStorage.getCardProgressForSet(widget.setId!);
        final setProgressByCardId = <String, CardProgress>{
          for (final p in setProgress) p.cardId: p,
        };
        if (studySet != null) {
          for (final card in studySet.cards) {
            final progress = setProgressByCardId[card.id];
            if (progress == null) continue;
            final isDue = progress.due == null || !progress.due!.isAfter(now);
            if (isDue) {
              items.add(_ReviewItem(card: card, progress: progress));
            }
          }
        }
      } else {
        final dueProgress = localStorage.getDueCardProgress();
        final cardsById = <String, Flashcard>{};
        for (final set in studySets) {
          for (final card in set.cards) {
            cardsById[card.id] = card;
          }
        }

        final tags = widget.filterTags;
        for (final progress in dueProgress) {
          final card = cardsById[progress.cardId];
          if (card == null) continue;
          if (tags != null &&
              tags.isNotEmpty &&
              !card.tags.any((t) => tags.contains(t))) {
            continue;
          }
          items.add(_ReviewItem(card: card, progress: progress));
        }
      }

      // Sort: Learning/Relearning first, then Review, then New; shuffle within groups
      _sortQueue(items);

      if (widget.maxCards != null &&
          widget.maxCards! > 0 &&
          items.length > widget.maxCards!) {
        items.removeRange(widget.maxCards!, items.length);
      }

      if (!mounted) return;
      setState(() {
        _queue = items;
        _currentIndex = 0;
      });
      if (items.isNotEmpty) {
        _voice.speakCardTerm(items.first.card.id, items.first.card.term);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _queueError = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isQueueLoading = false;
        });
      }
    }
  }

  /// Sort queue: Learning/Relearning (state 1,3) → Review (state 2) → New (state 0).
  /// Shuffle within each group.
  static void _sortQueue(List<_ReviewItem> items) {
    final rng = Random();
    items.shuffle(rng);
    items.sort((a, b) =>
        _queueSortOrder(a.progress.state).compareTo(
            _queueSortOrder(b.progress.state)));
  }

  static int _queueSortOrder(int state) {
    // state 1=Learning, 3=Relearning → 0 (first)
    // state 2=Review → 1
    // state 0=New → 2 (last)
    switch (state) {
      case 1:
      case 3:
        return 0;
      case 2:
        return 1;
      default:
        return 2;
    }
  }

  @override
  void dispose() {
    _voice.dispose();
    _flipController.dispose();
    _celebrateController?.dispose();
    super.dispose();
  }

  Future<void> _playCelebrationAndNavigate(VoidCallback navigate) async {
    final controller = AnimationController(
      vsync: this,
      duration: StudyConstants.celebrationDuration,
    );
    _celebrateController = controller;
    setState(() => _showCelebration = true);
    await controller.forward();
    if (!mounted) return;
    setState(() => _showCelebration = false);
    navigate();
  }

  void _flip() {
    // Timestamp-based debounce: skip flip if speak button was just tapped
    if (_lastSpeakTapAt != null &&
        DateTime.now().difference(_lastSpeakTapAt!).inMilliseconds < 200) {
      return;
    }
    if (_flipController.isAnimating || _isSubmittingRating) return;
    StudyHaptics.onCardFlip();
    setState(() => _isFlipped = true);
    _flipController.forward();
  }

  Future<void> _onRate(int rating) async {
    if (_isSubmittingRating || _queue.isEmpty) return;
    setState(() {
      _isSubmittingRating = true;
      _lastRating = rating;
    });

    final item = _queue[_currentIndex];
    final fsrsService = ref.read(fsrsServiceProvider);
    final localStorage = ref.read(localStorageServiceProvider);

    final result = fsrsService.reviewCard(item.progress, rating);
    await localStorage.saveCardProgress(result.progress);
    await localStorage.saveReviewLog(result.log);
    ref.invalidate(allCardProgressProvider);
    ref.invalidate(allReviewLogsProvider);
    ref.read(widgetRefreshProvider)();
    if (!mounted) return;

    // XP
    final earned = ref.read(sessionXpProvider.notifier).onSrsRating(rating);
    _xpToastKey.currentState?.showXp(earned);

    switch (rating) {
      case 1:
        _againCount++;
        break;
      case 2:
        _hardCount++;
        break;
      case 3:
        _goodCount++;
        break;
      case 4:
        _easyCount++;
        break;
    }

    // Again/Hard re-queue (Anki-style): add card back to end of queue
    if (rating <= 2) {
      _queue.add(_ReviewItem(card: item.card, progress: result.progress));
    }

    if (_currentIndex + 1 >= _queue.length) {
      final total = _againCount + _hardCount + _goodCount + _easyCount;
      final challengeTarget = widget.challengeTarget ?? widget.maxCards;
      final challengeCompleted =
          widget.challengeMode &&
          challengeTarget != null &&
          challengeTarget > 0 &&
          total >= challengeTarget;
      StudyHaptics.onComplete();
      setState(() {
        _isSubmittingRating = false;
        _lastRating = null;
      });
      // Play celebration then navigate
      await _playCelebrationAndNavigate(() {
        context.go(
          '/review/summary',
          extra: {
            'totalReviewed': total,
            'againCount': _againCount,
            'hardCount': _hardCount,
            'goodCount': _goodCount,
            'easyCount': _easyCount,
            'challengeMode': widget.challengeMode,
            'challengeTarget': challengeTarget,
            'challengeCompleted': challengeCompleted,
            'isRevengeMode': widget.revengeCardIds != null && widget.revengeCardIds!.isNotEmpty,
            'revengeCardCount': widget.revengeCardIds?.length ?? 0,
            'sessionXp': ref.read(sessionXpProvider).totalXp,
            'maxCombo': ref.read(sessionXpProvider).maxCombo,
          },
        );
      });
    } else {
      StudyHaptics.onNextCard();
      await Future<void>.delayed(const Duration(milliseconds: 140));
      if (!mounted) return;
      setState(() {
        _currentIndex++;
        _isFlipped = false;
        _isSubmittingRating = false;
        _lastRating = null;
      });
      _flipController.reset();
      _voice.speakCardTerm(
          _queue[_currentIndex].card.id, _queue[_currentIndex].card.term);
    }
  }

  void _goHomeSmooth() {
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final surfaceColor = Theme.of(context).colorScheme.surface;

    if (_isQueueLoading) {
      return Scaffold(
        appBar: AppBar(
          leading: const AppBackButton(),
          title: Text(l10n.srsReview),
        ),
        body: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            decoration: AppTheme.softCardDecoration(
              fillColor: surfaceColor,
              borderRadius: 14,
              borderColor: AppTheme.indigo.withValues(alpha: 0.22),
            ),
            child: const CircularProgressIndicator(),
          ),
        ),
      );
    }

    if (_queueError != null) {
      return Scaffold(
        appBar: AppBar(
          leading: const AppBackButton(),
          title: Text(l10n.srsReview),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
              decoration: AppTheme.softCardDecoration(
                fillColor: surfaceColor,
                borderRadius: 14,
                borderColor: AppTheme.red.withValues(alpha: 0.25),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.reviewQueueLoadFailed,
                    style: Theme.of(context).textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  if (kDebugMode) ...[
                    const SizedBox(height: 8),
                    Text(
                      _queueError!,
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _buildQueue,
                    child: Text(l10n.retryOrChooseAnother),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (_queue.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          leading: const AppBackButton(),
          title: Text(l10n.srsReview),
        ),
        body: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            decoration: AppTheme.softCardDecoration(
              fillColor: surfaceColor,
              borderRadius: 16,
              borderColor: AppTheme.green.withValues(alpha: 0.24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: AppTheme.green.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 48,
                    color: AppTheme.green,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  l10n.noDueCards,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 28),
                ElevatedButton(
                  onPressed: () => context.pop(),
                  child: Text(l10n.done),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final item = _queue[_currentIndex];
    if (_voice.lastSpokenCardId != item.card.id && !_isSubmittingRating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _voice.lastSpokenCardId != item.card.id) {
          _voice.speakCardTerm(item.card.id, item.card.term);
        }
      });
    }
    final fsrsService = ref.read(fsrsServiceProvider);
    final intervals = fsrsService.getSchedulingPreview(item.progress);
    final progress = _queue.isEmpty ? 0.0 : _currentIndex / _queue.length;

    return Scaffold(
      appBar: AppBar(
        leading: const AppBackButton(),
        title: Text(l10n.srsReview),
        actions: [
          IconButton(
            icon: const Icon(Icons.home_rounded),
            onPressed: _goHomeSmooth,
            tooltip: l10n.home,
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
        children: [
          RoundedProgressBar(
            value: progress,
            counterText: '${_currentIndex + 1} / ${_queue.length}',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
            child: Row(
              children: [
                Text(
                  l10n.reviewingLabel,
                  style: GoogleFonts.notoSerifTc(
                    textStyle: Theme.of(context).textTheme.bodySmall,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.indigo.withValues(alpha: 0.72),
                  ),
                ),
                const Spacer(),
                Text(
                  '${_currentIndex + 1} / ${_queue.length}',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: AppTheme.green,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                GestureDetector(
                  onTap: _isFlipped ? null : _flip,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
                    child: AnimatedScale(
                      scale: _isSubmittingRating ? 0.98 : 1,
                      duration: const Duration(milliseconds: 140),
                      child: Hero(
                        tag: 'flashcard_${item.card.id}',
                        child: AnimatedBuilder(
                          animation: _flipAnimation,
                          builder: (context, child) {
                            final angle = _flipAnimation.value * pi;
                            final isFront = _flipAnimation.value < 0.5;
                            final flipDepth =
                                sin(_flipAnimation.value * pi).abs();
                            final depthScale = 1 - (flipDepth * 0.015);
                            return Transform(
                              alignment: Alignment.center,
                              transform: Matrix4.identity()
                                ..setEntry(3, 2, 0.001)
                                ..scale(depthScale)
                                ..rotateY(angle),
                              child: isFront
                                  ? _buildCardSide(
                                      text: item.card.term,
                                      label: l10n.tapToFlip,
                                      onSpeak: () {
                                        _lastSpeakTapAt = DateTime.now();
                                        _voice.speakMultiLingual(
                                          item.card.term,
                                          userInitiated: true,
                                        );
                                      },
                                      bgColor: surfaceColor,
                                      textColor: Theme.of(
                                        context,
                                      ).colorScheme.onSurface,
                                      imageUrl: item.card.imageUrl,
                                      shadowBoost: flipDepth,
                                    )
                                  : Transform(
                                      alignment: Alignment.center,
                                      transform:
                                          Matrix4.identity()..rotateY(pi),
                                      child: _buildCardSide(
                                        text: item.card.definition,
                                        label: l10n.definitionLabel,
                                        onSpeak: () {
                                          _lastSpeakTapAt = DateTime.now();
                                          _voice.speakMultiLingual(
                                            item.card.definition,
                                            userInitiated: true,
                                          );
                                        },
                                        bgColor: surfaceColor,
                                        textColor: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                        shadowBoost: flipDepth,
                                      ),
                                    ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _isSubmittingRating ? 1 : 0,
                    duration: const Duration(milliseconds: 100),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _ratingLabel(_lastRating),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_isFlipped)
            Transform.translate(
              offset: const Offset(0, -14),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MnemonicButton(
                      cardId: item.card.id,
                      term: item.card.term,
                      definition: item.card.definition,
                    ),
                    RatingButtons(
                      intervals: intervals,
                      onRating: _onRate,
                      enabled: !_isSubmittingRating,
                    ),
                  ],
                ),
              ),
            )
          else
            Transform.translate(
              offset: const Offset(0, -10),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ReviewHintButton(
                      cardId: item.card.id,
                      term: item.card.term,
                      definition: item.card.definition,
                    ),
                    Text(
                      l10n.tapToFlip,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
          // Combo indicator
          const Positioned(
            top: 60,
            right: 16,
            child: ComboIndicator(),
          ),
          // XP toast
          Positioned(
            top: 100,
            left: 0,
            right: 0,
            child: Center(child: XpToastOverlay(key: _xpToastKey)),
          ),
          if (_showCelebration && _celebrateController != null)
            Positioned.fill(
              child: CompletionCelebrateOverlay(
                animation: _celebrateController!,
                color: AppTheme.green,
                tier: celebrationTierFromPercent(
                  ((_goodCount + _easyCount) /
                          (_againCount + _hardCount + _goodCount + _easyCount)
                              .clamp(1, 999) *
                          100)
                      .round(),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _ratingLabel(int? rating) {
    final l10n = AppLocalizations.of(context);
    switch (rating) {
      case 1:
        return l10n.ratingAgain;
      case 2:
        return l10n.ratingHard;
      case 3:
        return l10n.ratingGood;
      case 4:
        return l10n.ratingEasy;
      default:
        return '';
    }
  }

  Widget _buildCardSide({
    required String text,
    required String label,
    required Color bgColor,
    required Color textColor,
    VoidCallback? onSpeak,
    String imageUrl = '',
    double shadowBoost = 0,
  }) {
    final hasImage = imageUrl.isNotEmpty;
    final cardWidth = MediaQuery.sizeOf(context).width - 44;
    final cardHeight = cardWidth * 1.25;

    return Container(
      width: double.infinity,
      height: cardHeight,
      decoration: AppTheme.softCardDecoration(
        fillColor: bgColor,
        borderRadius: 18,
        borderColor:
            AppTheme.indigo.withValues(alpha: 0.22 + (shadowBoost * 0.08)),
        elevation: 1.2 + (shadowBoost * 1.4),
      ),
      child: Stack(
        children: [
          Column(
            children: [
              if (hasImage)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      color: Colors.grey.shade100,
                      child: CachedNetworkImage(
                        imageUrl: imageUrl,
                        height: cardHeight * 0.22,
                        width: double.infinity,
                        fit: BoxFit.contain,
                        errorWidget: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    const SizedBox(width: 32),
                    Expanded(
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.notoSerifTc(
                          textStyle: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: textColor.withValues(alpha: 0.5),
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: IconButton(
                        onPressed: onSpeak,
                        tooltip: AppLocalizations.of(context).listen,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Icons.volume_up_rounded,
                          color: textColor.withValues(alpha: 0.72),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 20,
                    ),
                    child: Text(
                      text,
                      style: GoogleFonts.notoSerifTc(
                        textStyle: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                          height: 1.3,
                        ),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ],
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.16 + (shadowBoost * 0.1)),
                      Colors.white.withValues(alpha: 0.03),
                      Colors.transparent,
                    ],
                    stops: const [0, 0.28, 1],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewItem {
  final Flashcard card;
  final CardProgress progress;

  _ReviewItem({required this.card, required this.progress});
}
