import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:recall_app/core/services/study_haptics.dart';
import 'package:recall_app/providers/session_xp_provider.dart';
import 'package:recall_app/features/study/widgets/combo_indicator.dart';
import 'package:recall_app/features/study/widgets/xp_toast.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/core/widgets/app_back_button.dart';
import 'package:recall_app/features/study/widgets/completion_celebrate_overlay.dart';
import 'package:recall_app/features/study/widgets/matching_tile.dart';
import 'package:recall_app/models/flashcard.dart';
import 'package:recall_app/providers/fsrs_provider.dart';
import 'package:recall_app/providers/study_set_provider.dart';
import 'package:recall_app/providers/stats_provider.dart';

class MatchingGameScreen extends ConsumerStatefulWidget {
  final String setId;
  final int? pairCount;

  const MatchingGameScreen({super.key, required this.setId, this.pairCount});

  @override
  ConsumerState<MatchingGameScreen> createState() => _MatchingGameScreenState();
}

class _MatchingGameScreenState extends ConsumerState<MatchingGameScreen>
    with TickerProviderStateMixin {
  static const Color _bg = Color(0xFFF8F4E8);
  static const Color _primary = Color(0xFF6F8451);
  static const Color _sageLight = Color(0xFFD9E4C7);

  List<Flashcard> _gameCards = [];
  List<_TileItem> _tiles = [];
  int? _selectedIndex;
  final Set<String> _matchedCardIds = {};
  final Set<int> _incorrectIndices = {};
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _ticker;
  late final AnimationController _gridIntroController;
  late final AnimationController _completionController;
  int _attempts = 0;
  int _elapsedSeconds = 0;
  bool _hasStarted = false;
  bool _showCompletionCelebrate = false;
  bool _navigatingToResult = false;
  bool _outcomesDirty = false;
  final Set<Future<void>> _pendingOutcomeWrites = <Future<void>>{};
  final _xpToastKey = GlobalKey<XpToastOverlayState>();

  @override
  void initState() {
    super.initState();
    _gridIntroController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 640),
    );
    _completionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 920),
    );
    _initGame();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _gridIntroController.dispose();
    _completionController.dispose();
    _stopwatch.stop();
    super.dispose();
  }

  void _initGame() {
    final studySet = ref.read(studySetsProvider.notifier).getById(widget.setId);
    if (studySet == null) return;

    final maxPairs = widget.pairCount ?? 6;
    final cards = List.of(studySet.cards)..shuffle(Random());
    _gameCards = cards.take(min(maxPairs, cards.length)).toList();

    _tiles = [];
    for (final card in _gameCards) {
      _tiles.add(_TileItem(cardId: card.id, text: card.term, isTerm: true));
      _tiles.add(
        _TileItem(cardId: card.id, text: card.definition, isTerm: false),
      );
    }
    _tiles.shuffle(Random());

    _selectedIndex = null;
    _matchedCardIds.clear();
    _incorrectIndices.clear();
    _attempts = 0;
    _elapsedSeconds = 0;
    _hasStarted = false;
    _showCompletionCelebrate = false;
    _navigatingToResult = false;
    _gridIntroController.value = 0;
    _completionController.value = 0;
    _ticker?.cancel();
    _stopwatch.reset();
  }

  void _startGame() {
    if (_hasStarted) return;
    setState(() {
      _hasStarted = true;
      _elapsedSeconds = 0;
      _attempts = 0;
    });
    _ticker?.cancel();
    _stopwatch
      ..reset()
      ..start();
    _gridIntroController.forward(from: 0);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsedSeconds = _stopwatch.elapsed.inSeconds;
      });
    });
  }

  void _onTileTap(int index) {
    if (!_hasStarted) return;
    if (_matchedCardIds.contains(_tiles[index].cardId)) return;
    if (_incorrectIndices.isNotEmpty) return;

    if (_selectedIndex == null) {
      setState(() => _selectedIndex = index);
      return;
    }

    if (_selectedIndex == index) {
      setState(() => _selectedIndex = null);
      return;
    }

    final first = _tiles[_selectedIndex!];
    final second = _tiles[index];
    _attempts++;

    if (first.cardId == second.cardId && first.isTerm != second.isTerm) {
      StudyHaptics.onMatch();
      final earned = ref.read(sessionXpProvider.notifier).onCorrect();
      _xpToastKey.currentState?.showXp(earned);
      _trackOutcomeWrite(_recordMatchOutcome(first.cardId, rating: 3));
      setState(() {
        _matchedCardIds.add(first.cardId);
        _selectedIndex = null;
      });

      if (_matchedCardIds.length == _gameCards.length) {
        StudyHaptics.onComplete();
        _ticker?.cancel();
        _stopwatch.stop();
        _playCompletionCelebrateThenShowResults();
      }
    } else {
      StudyHaptics.onMismatch();
      ref.read(sessionXpProvider.notifier).onIncorrect();
      _trackOutcomeWrite(
        _recordMismatchOutcome(
          firstCardId: first.cardId,
          secondCardId: second.cardId,
        ),
      );
      setState(() {
        _incorrectIndices.addAll([_selectedIndex!, index]);
      });

      Future.delayed(const Duration(milliseconds: 560), () {
        if (!mounted) return;
        setState(() {
          _incorrectIndices.clear();
          _selectedIndex = null;
        });
      });
    }
  }

  void _trackOutcomeWrite(Future<void> future) {
    _pendingOutcomeWrites.add(future);
    unawaited(future.whenComplete(() => _pendingOutcomeWrites.remove(future)));
  }

  Future<void> _recordMatchOutcome(String cardId, {required int rating}) async {
    try {
      await ref
          .read(studyOutcomeRecorderProvider)
          .recordRating(
            cardId: cardId,
            setId: widget.setId,
            rating: rating,
            reviewType: 'match',
            metadata: <String, dynamic>{'matched': true},
          );
      _outcomesDirty = true;
    } catch (e) {
      debugPrint('Failed to record matching outcome: $e');
    }
  }

  Future<void> _recordMismatchOutcome({
    required String firstCardId,
    required String secondCardId,
  }) async {
    try {
      final recorder = ref.read(studyOutcomeRecorderProvider);
      await recorder.recordRating(
        cardId: firstCardId,
        setId: widget.setId,
        rating: 2,
        reviewType: 'match',
        chosenDistractorId: secondCardId,
        metadata: <String, dynamic>{
          'matched': false,
          'confusedWithCardId': secondCardId,
        },
      );
      await recorder.recordRating(
        cardId: secondCardId,
        setId: widget.setId,
        rating: 2,
        reviewType: 'match',
        chosenDistractorId: firstCardId,
        metadata: <String, dynamic>{
          'matched': false,
          'confusedWithCardId': firstCardId,
        },
      );
      _outcomesDirty = true;
    } catch (e) {
      debugPrint('Failed to record matching mismatch: $e');
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

  Future<void> _showResults() async {
    if (_navigatingToResult) return;
    await _flushOutcomeInvalidations();
    if (!mounted) return;
    _navigatingToResult = true;
    final accuracy = _attempts == 0
        ? 100
        : ((_gameCards.length / _attempts) * 100).clamp(0, 100).round();
    context.pushReplacement(
      '/study/${widget.setId}/match/result',
      extra: <String, dynamic>{
        'elapsedSeconds': _elapsedSeconds,
        'accuracy': accuracy,
        'attempts': _attempts,
        'pairCount': widget.pairCount,
      },
    );
  }

  Future<void> _playCompletionCelebrateThenShowResults() async {
    if (_showCompletionCelebrate) return;
    setState(() {
      _showCompletionCelebrate = true;
    });
    await _completionController.forward(from: 0);
    if (!mounted) return;
    await _showResults();
  }

  Future<void> _goHomeSmooth() async {
    await _flushOutcomeInvalidations();
    if (!mounted) return;
    context.go('/');
  }

  String _formatElapsed(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final studySet = ref
        .watch(studySetsProvider)
        .where((s) => s.id == widget.setId)
        .firstOrNull;
    final l10n = AppLocalizations.of(context);

    if (studySet == null || studySet.cards.length < 2) {
      return Scaffold(
        appBar: AppBar(
          leading: const AppBackButton(),
          title: Text(l10n.matchingGame),
        ),
        body: Center(child: Text(l10n.needAtLeast2Cards)),
      );
    }

    final progress = _gameCards.isEmpty
        ? 0.0
        : _matchedCardIds.length / _gameCards.length;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: _primary),
        leading: const AppBackButton(),
        title: Text(
          l10n.matchingGame.toUpperCase(),
          style: GoogleFonts.notoSerifTc(
            textStyle: const TextStyle(
              fontWeight: FontWeight.w800,
              letterSpacing: 1.6,
              color: _primary,
            ),
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: _primary),
            onPressed: () => setState(_initGame),
            tooltip: l10n.restart,
          ),
          IconButton(
            icon: const Icon(Icons.home_rounded, color: _primary),
            onPressed: _goHomeSmooth,
            tooltip: l10n.home,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: _primary.withValues(alpha: 0.1), height: 1),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF8F4E8), Color(0xFFF3EDD9)],
          ),
        ),
        child: Stack(
          children: [
            Column(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 360),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    return FadeTransition(opacity: animation, child: child);
                  },
                  child: _hasStarted
                      ? Padding(
                          key: const ValueKey('started_header'),
                          padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.88),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: _primary.withValues(alpha: 0.2),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: _primary.withValues(alpha: 0.12),
                                  blurRadius: 16,
                                  offset: const Offset(0, 5),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.timer_outlined,
                                      size: 20,
                                      color: _primary,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      _formatElapsed(_elapsedSeconds),
                                      style: GoogleFonts.notoSerifTc(
                                        textStyle: const TextStyle(
                                          fontSize: 28,
                                          fontWeight: FontWeight.w800,
                                          color: _primary,
                                          height: 1,
                                        ),
                                      ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      '${_matchedCardIds.length} / ${_gameCards.length}',
                                      style: GoogleFonts.notoSerifTc(
                                        textStyle: const TextStyle(
                                          fontSize: 20,
                                          color: _primary,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: SizedBox(
                                    height: 11,
                                    child: Stack(
                                      children: [
                                        Container(color: _sageLight),
                                        TweenAnimationBuilder<double>(
                                          tween: Tween<double>(
                                            begin: 0,
                                            end: progress.clamp(0, 1),
                                          ),
                                          duration: const Duration(
                                            milliseconds: 420,
                                          ),
                                          curve: Curves.easeOutCubic,
                                          builder: (context, value, _) {
                                            return FractionallySizedBox(
                                              widthFactor: value,
                                              child: Container(
                                                decoration: const BoxDecoration(
                                                  gradient: LinearGradient(
                                                    colors: [
                                                      Color(0xFF7E955E),
                                                      Color(0xFF55763E),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : const SizedBox(
                          key: ValueKey('idle_header'),
                          height: 12,
                        ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 420),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      return FadeTransition(opacity: animation, child: child);
                    },
                    child: !_hasStarted
                        ? Center(
                            key: const ValueKey('ready_panel'),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                24,
                                16,
                                24,
                                20,
                              ),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.fromLTRB(
                                  18,
                                  20,
                                  18,
                                  18,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.92),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: _primary.withValues(alpha: 0.22),
                                    width: 1.2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: _primary.withValues(alpha: 0.14),
                                      blurRadius: 16,
                                      offset: const Offset(0, 6),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    TweenAnimationBuilder<double>(
                                      tween: Tween<double>(begin: 0.96, end: 1),
                                      duration: const Duration(
                                        milliseconds: 720,
                                      ),
                                      curve: Curves.easeOutBack,
                                      builder: (context, scale, child) =>
                                          Transform.scale(
                                            scale: scale,
                                            child: child,
                                          ),
                                      child: Icon(
                                        Icons.grid_view_rounded,
                                        color: _primary.withValues(alpha: 0.95),
                                        size: 38,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      l10n.matchingReady,
                                      style: GoogleFonts.notoSerifTc(
                                        textStyle: const TextStyle(
                                          fontSize: 24,
                                          fontWeight: FontWeight.w800,
                                          color: _primary,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      '${_gameCards.length} ${l10n.pairsLabel}',
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: _primary.withValues(alpha: 0.8),
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    SizedBox(
                                      width: double.infinity,
                                      child: FilledButton(
                                        onPressed: _startGame,
                                        style: FilledButton.styleFrom(
                                          backgroundColor: _primary,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 12,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                        ),
                                        child: Text(
                                          l10n.start,
                                          style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 0.6,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          )
                        : Padding(
                            key: const ValueKey('grid_panel'),
                            padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final crossCount = _gameCards.length <= 3
                                    ? 2
                                    : 3;
                                final spacing = 10.0;
                                final tileCount = _tiles.length;
                                final rowCount = (tileCount / crossCount)
                                    .ceil();
                                final availH =
                                    constraints.maxHeight -
                                    (rowCount - 1) * spacing;
                                final availW =
                                    constraints.maxWidth -
                                    (crossCount - 1) * spacing;
                                final tileH = availH / rowCount;
                                final tileW = availW / crossCount;
                                final aspect = tileW / tileH;

                                return RepaintBoundary(
                                  child: AnimatedBuilder(
                                    animation: _gridIntroController,
                                    builder: (context, _) {
                                      return GridView.builder(
                                        physics:
                                            const NeverScrollableScrollPhysics(),
                                        gridDelegate:
                                            SliverGridDelegateWithFixedCrossAxisCount(
                                              crossAxisCount: crossCount,
                                              childAspectRatio: aspect.clamp(
                                                0.78,
                                                1.1,
                                              ),
                                              crossAxisSpacing: spacing,
                                              mainAxisSpacing: spacing,
                                            ),
                                        itemCount: tileCount,
                                        itemBuilder: (context, index) {
                                          final tile = _tiles[index];
                                          MatchingTileState state;

                                          if (_matchedCardIds.contains(
                                            tile.cardId,
                                          )) {
                                            state = MatchingTileState.matched;
                                          } else if (_incorrectIndices.contains(
                                            index,
                                          )) {
                                            state = MatchingTileState.incorrect;
                                          } else if (_selectedIndex == index) {
                                            state = MatchingTileState.selected;
                                          } else {
                                            state = MatchingTileState.normal;
                                          }

                                          final denom = tileCount <= 1
                                              ? 1
                                              : tileCount - 1;
                                          final start = (index / denom) * 0.35;
                                          final end = (start + 0.35).clamp(
                                            0.0,
                                            1.0,
                                          );
                                          final curve = Interval(
                                            start,
                                            end,
                                            curve: Curves.easeOutCubic,
                                          );
                                          final t = curve.transform(
                                            _gridIntroController.value,
                                          );

                                          return Opacity(
                                            opacity: t,
                                            child: Transform.translate(
                                              offset: Offset(0, (1 - t) * 12),
                                              child: MatchingTile(
                                                text: tile.text,
                                                state: state,
                                                onTap: () => _onTileTap(index),
                                              ),
                                            ),
                                          );
                                        },
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                          ),
                  ),
                ),
              ],
            ),
            // Combo indicator
            const Positioned(top: 8, right: 16, child: ComboIndicator()),
            // XP toast
            Positioned(
              top: 50,
              left: 0,
              right: 0,
              child: Center(child: XpToastOverlay(key: _xpToastKey)),
            ),
            if (_showCompletionCelebrate)
              Positioned.fill(
                child: IgnorePointer(
                  child: CompletionCelebrateOverlay(
                    animation: _completionController,
                    color: _primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TileItem {
  final String cardId;
  final String text;
  final bool isTerm;

  _TileItem({required this.cardId, required this.text, required this.isTerm});
}

class _MatchingResultDialogContent extends StatefulWidget {
  final Color accentColor;
  final String title;
  final String primaryText;
  final int accuracyPercent;
  final String attemptsLabel;
  final int attemptsCount;
  final String leftLabel;
  final String rightLabel;
  final VoidCallback onLeft;
  final VoidCallback onRight;

  const _MatchingResultDialogContent({
    required this.accentColor,
    required this.title,
    required this.primaryText,
    required this.accuracyPercent,
    required this.attemptsLabel,
    required this.attemptsCount,
    required this.leftLabel,
    required this.rightLabel,
    required this.onLeft,
    required this.onRight,
  });

  @override
  State<_MatchingResultDialogContent> createState() =>
      _MatchingResultDialogContentState();
}

class _MatchingResultDialogContentState
    extends State<_MatchingResultDialogContent>
    with SingleTickerProviderStateMixin {
  static const double _panelWidth = 328;
  late final AnimationController _revealController;

  @override
  void initState() {
    super.initState();
    _revealController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1550),
    )..forward();
  }

  @override
  void dispose() {
    _revealController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: _revealController,
      builder: (context, _) {
        final statsT = const Interval(
          0.34,
          0.75,
          curve: Curves.easeOutCubic,
        ).transform(_revealController.value);
        final actionsT = const Interval(
          0.62,
          1.0,
          curve: Curves.easeOutCubic,
        ).transform(_revealController.value);

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: _panelWidth,
              child: _MatchingCelebrateHeader(
                accentColor: widget.accentColor,
                title: widget.title,
                primaryText: widget.primaryText,
              ),
            ),
            const SizedBox(height: 12),
            Opacity(
              opacity: statsT,
              child: Transform.translate(
                offset: Offset(0, (1 - statsT) * 14),
                child: Container(
                  width: _panelWidth,
                  padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: widget.accentColor.withValues(alpha: 0.16),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: widget.accentColor.withValues(alpha: 0.1),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Expanded(
                        child: _WelcomeStatBlock(
                          label: l10n.matchingTime,
                          value: widget.primaryText,
                          color: const Color(0xFF2D2D2A),
                        ),
                      ),
                      _StatDivider(color: widget.accentColor),
                      Expanded(
                        child: _WelcomeStatBlock(
                          label: l10n.matchingAccuracy,
                          value: '${widget.accuracyPercent}%',
                          color: widget.accentColor,
                        ),
                      ),
                      _StatDivider(color: widget.accentColor),
                      Expanded(
                        child: _WelcomeStatBlock(
                          label: l10n.matchingAttempts,
                          value: '${widget.attemptsCount}',
                          color: const Color(0xFF2D2D2A),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Opacity(
              opacity: actionsT,
              child: Transform.translate(
                offset: Offset(0, (1 - actionsT) * 12),
                child: Center(
                  child: SizedBox(
                    width: _panelWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: widget.onLeft,
                            style: FilledButton.styleFrom(
                              backgroundColor: widget.accentColor,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 13),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              widget.leftLabel,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: widget.onRight,
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                color: widget.accentColor.withValues(
                                  alpha: 0.3,
                                ),
                                width: 1.4,
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 13),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              widget.rightLabel,
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: widget.accentColor,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _WelcomeStatBlock extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _WelcomeStatBlock({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 0.6,
            color: Colors.black.withValues(alpha: 0.42),
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          textAlign: TextAlign.center,
          style: GoogleFonts.notoSerifTc(
            textStyle: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: color,
              height: 1,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatDivider extends StatelessWidget {
  final Color color;

  const _StatDivider({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 42,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: color.withValues(alpha: 0.18),
    );
  }
}

class _MatchingCelebrateHeader extends StatefulWidget {
  final Color accentColor;
  final String title;
  final String primaryText;

  const _MatchingCelebrateHeader({
    required this.accentColor,
    required this.title,
    required this.primaryText,
  });

  @override
  State<_MatchingCelebrateHeader> createState() =>
      _MatchingCelebrateHeaderState();
}

class _MatchingCelebrateHeaderState extends State<_MatchingCelebrateHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = Curves.easeOutBack.transform(
          (_controller.value * 1.04).clamp(0.0, 1.0),
        );
        final burst = (1 - t).clamp(0.0, 1.0);
        final iconScale = (0.72 + (t * 0.28)) + sin(t * pi * 2.2) * 0.07;
        final sparkleT = const Interval(
          0.25,
          1.0,
          curve: Curves.easeOut,
        ).transform(_controller.value);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 164,
              height: 118,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 102 + (34 * burst),
                    height: 102 + (34 * burst),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.accentColor.withValues(
                        alpha: 0.15 * (1 - burst),
                      ),
                    ),
                  ),
                  for (var i = 0; i < 12; i++)
                    _ConfettiDot(
                      index: i,
                      count: 12,
                      progress: t,
                      color:
                          Color.lerp(
                            widget.accentColor,
                            const Color(0xFFFFD86B),
                            (i % 4) * 0.24,
                          ) ??
                          widget.accentColor,
                    ),
                  Positioned(
                    top: 16,
                    left: 28,
                    child: Opacity(
                      opacity: sparkleT * 0.9,
                      child: const Icon(
                        Icons.auto_awesome,
                        size: 18,
                        color: Color(0xFFFFD86B),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 16,
                    right: 28,
                    child: Opacity(
                      opacity: sparkleT * 0.85,
                      child: const Icon(
                        Icons.auto_awesome,
                        size: 14,
                        color: Color(0xFFFFC55A),
                      ),
                    ),
                  ),
                  Transform.scale(
                    scale: iconScale,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: widget.accentColor.withValues(alpha: 0.38),
                          width: 1.8,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: widget.accentColor.withValues(alpha: 0.32),
                            blurRadius: 18,
                            offset: const Offset(0, 7),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.celebration_rounded,
                        color: widget.accentColor,
                        size: 38,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              widget.title,
              style: textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: widget.accentColor,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Container(
              width: 180,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: widget.accentColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: widget.accentColor.withValues(alpha: 0.28),
                  width: 1.2,
                ),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  widget.primaryText,
                  textAlign: TextAlign.center,
                  style: textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: widget.accentColor,
                    height: 1.0,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ConfettiDot extends StatelessWidget {
  final int index;
  final int count;
  final double progress;
  final Color color;

  const _ConfettiDot({
    required this.index,
    required this.count,
    required this.progress,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final angle = ((index / count) * pi * 2) - (pi / 2);
    final distance = 14 + (progress * 42);
    final dx = cos(angle) * distance;
    final dy = sin(angle) * distance + (1 - progress) * 10;
    final alpha = (0.84 - (progress * 0.52)).clamp(0.0, 1.0);
    final size = 5 + (index % 4).toDouble();

    return Transform.translate(
      offset: Offset(dx, dy),
      child: Opacity(
        opacity: alpha,
        child: Transform.rotate(
          angle: progress * pi * 1.6 + (index * 0.18),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2.8),
            ),
          ),
        ),
      ),
    );
  }
}
