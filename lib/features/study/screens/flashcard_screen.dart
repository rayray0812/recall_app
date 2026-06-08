import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:recall_app/core/constants/study_constants.dart';
import 'package:recall_app/core/services/study_haptics.dart';
import 'package:recall_app/core/theme/app_theme.dart';
import 'package:recall_app/core/widgets/app_back_button.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/features/study/utils/encouragement_lines.dart';
import 'package:recall_app/features/study/utils/part_of_speech.dart';
import 'package:recall_app/features/study/widgets/combo_indicator.dart';
import 'package:recall_app/features/study/widgets/completion_celebrate_overlay.dart';
import 'package:recall_app/features/study/widgets/rounded_progress_bar.dart';
import 'package:recall_app/features/study/widgets/study_result_widgets.dart';
import 'package:recall_app/features/study/widgets/swipe_card_stack.dart';
import 'package:recall_app/features/study/widgets/xp_toast.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:recall_app/models/flashcard.dart';
import 'package:recall_app/providers/fsrs_provider.dart';
import 'package:recall_app/providers/stats_provider.dart';
import 'package:recall_app/providers/session_xp_provider.dart';
import 'package:recall_app/providers/study_set_provider.dart';

class FlashcardScreen extends ConsumerStatefulWidget {
  final String setId;

  const FlashcardScreen({super.key, required this.setId});

  @override
  ConsumerState<FlashcardScreen> createState() => _FlashcardScreenState();
}

class _FlashcardScreenState extends ConsumerState<FlashcardScreen>
    with TickerProviderStateMixin {
  final GlobalKey<SwipeCardStackState> _stackKey =
      GlobalKey<SwipeCardStackState>();
  List<Flashcard> _currentCards = const [];
  final List<Flashcard> _knownCards = [];
  final List<Flashcard> _unknownCards = [];
  int _swipedCount = 0;
  bool _roundDone = false;
  AnimationController? _celebrateController;
  bool _showCelebration = false;
  bool _outcomesDirty = false;
  final Set<Future<void>> _pendingOutcomeWrites = <Future<void>>{};
  final _xpToastKey = GlobalKey<XpToastOverlayState>();

  @override
  void initState() {
    super.initState();
    _startRound(null);
  }

  @override
  void dispose() {
    _celebrateController?.dispose();
    super.dispose();
  }

  void _startRound(List<Flashcard>? cards) {
    final studySet = ref.read(studySetsProvider.notifier).getById(widget.setId);
    if (studySet == null) return;

    setState(() {
      _currentCards = List.of(cards ?? studySet.cards)..shuffle();
      _knownCards.clear();
      _unknownCards.clear();
      _swipedCount = 0;
      _roundDone = false;
    });
  }

  void _onSwiped(int index, bool remembered) {
    final sourceCards = _currentCards.isEmpty
        ? ref.read(studySetsProvider.notifier).getById(widget.setId)?.cards ??
              const <Flashcard>[]
        : _currentCards;
    if (index >= sourceCards.length) return;

    final card = sourceCards[index];
    if (remembered) {
      final earned = ref
          .read(sessionXpProvider.notifier)
          .onFlashcardRemembered();
      _xpToastKey.currentState?.showXp(earned);
    } else {
      ref.read(sessionXpProvider.notifier).onFlashcardForgot();
    }
    setState(() {
      if (remembered) {
        _knownCards.add(card);
      } else {
        _unknownCards.add(card);
      }
      _swipedCount++;
      if (_swipedCount >= sourceCards.length) {
        StudyHaptics.onComplete();
        _playCelebrationThenShowRoundEnd();
      }
    });

    _trackOutcomeWrite(_recordFlashcardOutcome(card, remembered: remembered));
  }

  void _trackOutcomeWrite(Future<void> future) {
    _pendingOutcomeWrites.add(future);
    unawaited(future.whenComplete(() => _pendingOutcomeWrites.remove(future)));
  }

  Future<void> _recordFlashcardOutcome(
    Flashcard card, {
    required bool remembered,
  }) async {
    try {
      await ref
          .read(studyOutcomeRecorderProvider)
          .recordRating(
            cardId: card.id,
            setId: widget.setId,
            rating: remembered ? 3 : 1,
            reviewType: 'flashcard',
            metadata: <String, dynamic>{'remembered': remembered},
          );
      _outcomesDirty = true;
    } catch (e) {
      debugPrint('Failed to record flashcard outcome: $e');
    }
  }

  Future<void> _flushOutcomeInvalidations() async {
    if (_pendingOutcomeWrites.isNotEmpty) {
      await Future.wait(_pendingOutcomeWrites.toList());
    }
    if (!_outcomesDirty) return;
    _outcomesDirty = false;
    ref.invalidate(allCardProgressProvider);
    ref.invalidate(allReviewLogsProvider);
  }

  Future<void> _playCelebrationThenShowRoundEnd() async {
    final controller = AnimationController(
      vsync: this,
      duration: StudyConstants.celebrationDuration,
    );
    _celebrateController = controller;
    setState(() => _showCelebration = true);
    await controller.forward();
    if (!mounted) return;
    await _flushOutcomeInvalidations();
    if (!mounted) return;
    setState(() {
      _showCelebration = false;
      _roundDone = true;
    });
  }

  Future<void> _goHomeSmooth() async {
    await _flushOutcomeInvalidations();
    if (!mounted) return;
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final studySet = ref
        .watch(studySetsProvider)
        .where((s) => s.id == widget.setId)
        .firstOrNull;

    final l10n = AppLocalizations.of(context);

    if (studySet == null || studySet.cards.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          leading: const AppBackButton(),
          title: Text(l10n.flashcards),
        ),
        body: Center(child: Text(l10n.noCardsAvailable)),
      );
    }

    if (_currentCards.isEmpty &&
        _knownCards.isEmpty &&
        _unknownCards.isEmpty &&
        !_roundDone) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _currentCards.isNotEmpty) return;
        _startRound(null);
      });
    }

    final activeCards = _currentCards.isEmpty ? studySet.cards : _currentCards;
    final progress = activeCards.isEmpty
        ? 0.0
        : _swipedCount / activeCards.length;

    return Scaffold(
      appBar: AppBar(
        leading: const AppBackButton(),
        title: Text(l10n.flashcards),
        actions: [
          IconButton(
            icon: const Icon(CupertinoIcons.house, size: 22),
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
                counterText: '$_swipedCount / ${activeCards.length}',
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
                child: Row(
                  children: [
                    _CountPill(
                      color: AppTheme.red,
                      icon: CupertinoIcons.xmark_circle,
                      label: l10n.dontKnow,
                      count: _unknownCards.length,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        child: Text(
                          'Left: ${l10n.dontKnow} / Right: ${l10n.know} / Tap to flip',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _CountPill(
                      color: AppTheme.green,
                      icon: CupertinoIcons.check_mark_circled,
                      label: l10n.know,
                      count: _knownCards.length,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _roundDone
                    ? _buildRoundEnd(context)
                    : _buildCardStack(activeCards),
              ),
              if (!_roundDone) _buildSwipeActionBar(context, l10n),
            ],
          ),
          const Positioned(top: 60, right: 16, child: ComboIndicator()),
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
                  activeCards.isEmpty
                      ? 0
                      : (_knownCards.length / activeCards.length * 100).round(),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCardStack(List<Flashcard> activeCards) {
    final swipeCards = activeCards
        .map(
          (c) => SwipeCardData(
            term: c.term,
            definition: c.definition,
            imageUrl: c.imageUrl,
            posTags: extractPartOfSpeechTags(c.tags),
          ),
        )
        .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: SwipeCardStack(
        key: _stackKey,
        cards: swipeCards,
        onSwiped: _onSwiped,
      ),
    );
  }

  Widget _buildSwipeActionBar(BuildContext context, AppLocalizations l10n) {
    final canTapActions =
        _stackKey.currentState?.canSwipeProgrammatically ?? true;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: canTapActions
                    ? () => _stackKey.currentState?.swipeForgot()
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.red.withValues(alpha: 0.92),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(CupertinoIcons.xmark, size: 18),
                label: Text(l10n.dontKnow),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: canTapActions
                    ? () => _stackKey.currentState?.swipeRemembered()
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.green.withValues(alpha: 0.94),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(CupertinoIcons.check_mark, size: 18),
                label: Text(l10n.know),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoundEnd(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final allKnown = _unknownCards.isEmpty;
    final total = _knownCards.length + _unknownCards.length;
    final percent = total == 0 ? 0 : (_knownCards.length / total * 100).round();
    final accent = allKnown ? AppTheme.green : AppTheme.indigo;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: StudyResultCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StudyResultHeader(
                accentColor: accent,
                icon: allKnown
                    ? Icons.celebration_rounded
                    : Icons.stacked_bar_chart_rounded,
                title: allKnown ? l10n.greatJob : l10n.roundComplete,
                primaryText: l10n.percentCorrect(percent),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _StatBox(
                    label: l10n.know,
                    count: _knownCards.length,
                    color: AppTheme.green,
                  ),
                  _StatBox(
                    label: l10n.dontKnow,
                    count: _unknownCards.length,
                    color: AppTheme.red,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                EncouragementLines.pick(percent),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 22),
              if (_unknownCards.isNotEmpty)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _startRound(_unknownCards),
                    icon: const Icon(Icons.replay_rounded),
                    label: Text(
                      l10n.reviewNUnknownCards(_unknownCards.length),
                      style: GoogleFonts.notoSerifTc(
                        textStyle: Theme.of(context).textTheme.labelLarge,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              if (_unknownCards.isNotEmpty) const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: Text(
                    l10n.done,
                    style: GoogleFonts.notoSerifTc(
                      textStyle: Theme.of(context).textTheme.titleSmall,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String label;
  final int count;

  const _CountPill({
    required this.color,
    required this.icon,
    required this.label,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$label: $count',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              '$count',
              style: GoogleFonts.notoSerifTc(
                color: color,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _StatBox({
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return StudyResultChip(
      label: label,
      value: '$count',
      color: color,
      minWidth: 130,
    );
  }
}
