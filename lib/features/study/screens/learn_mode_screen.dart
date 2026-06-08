import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/core/theme/app_theme.dart';
import 'package:recall_app/core/widgets/app_back_button.dart';
import 'package:recall_app/core/widgets/app_feedback_toast.dart';
import 'package:recall_app/features/study/services/voice_playback_service.dart';
import 'package:recall_app/features/study/utils/encouragement_lines.dart';
import 'package:recall_app/features/study/widgets/quiz_option_tile.dart';
import 'package:recall_app/features/study/widgets/rounded_progress_bar.dart';
import 'package:recall_app/features/study/widgets/study_result_widgets.dart';
import 'package:recall_app/features/study/widgets/text_input_question.dart';
import 'package:recall_app/models/flashcard.dart';
import 'package:recall_app/providers/fsrs_provider.dart';
import 'package:recall_app/providers/stats_provider.dart';
import 'package:recall_app/services/local_storage_service.dart';
import 'package:recall_app/providers/study_set_provider.dart';

enum _LearnQuestionType { multipleChoice, textInput }

enum _LearnDirection { termToDefinition, definitionToTerm }

class LearnModeScreen extends ConsumerStatefulWidget {
  final String setId;

  const LearnModeScreen({super.key, required this.setId});

  @override
  ConsumerState<LearnModeScreen> createState() => _LearnModeScreenState();
}

class _LearnModeScreenState extends ConsumerState<LearnModeScreen> {
  static const int _masteryStage = 2;

  final Random _random = Random();
  final Map<String, int> _stageByCardId = <String, int>{};
  final Map<String, int> _wrongCountByCardId = <String, int>{};
  final List<String> _queue = <String>[];

  late List<Flashcard> _allCards;
  late Map<String, Flashcard> _cardById;
  late List<List<String>> _chapterCardIds;
  late List<bool> _chapterCompleted;

  String? _currentCardId;
  int _chapterIndex = 0;
  int _attempts = 0;
  int _correct = 0;
  int _totalAttempts = 0;
  int _totalCorrect = 0;
  int _streak = 0;
  int _bestStreak = 0;
  int _consecutiveWrong = 0;
  int _rescueQuestionsLeft = 0;
  int _hintUsedTotal = 0;
  bool _hintUsedOnCurrentQuestion = false;
  bool _chapterCheckpointShown = false;
  bool _rescueAppliedForCurrentCard = false;
  String _lastAutoSpeakKey = '';
  bool _turnFeedbackVisible = false;
  bool _turnFeedbackCorrect = false;
  String _turnFeedbackTitle = '';
  String _turnFeedbackSubtitle = '';
  String _lastCoachNoticeKey = '';
  double _questionCardScale = 1.0;
  double _questionCardShakeX = 0.0;
  int _questionCardAnimToken = 0;
  int _lastChapterProgressMilestone = 0;
  bool _progressGlowActive = false;
  bool _outcomesDirty = false;
  final Set<Future<void>> _pendingOutcomeWrites = <Future<void>>{};

  int? _selectedOption;
  String? _questionSeedCardId;
  bool? _questionSeedRescueMode;
  _LearnQuestionType? _questionSeedType;
  _LearnDirection? _questionSeedDirection;
  String? _choiceSeedCardId;
  _LearnDirection? _choiceSeedDirection;
  List<Flashcard> _choiceSeedOptions = <Flashcard>[];
  _LearnDirection _currentDirection = _LearnDirection.termToDefinition;

  late DateTime _startedAt;
  late final VoicePlaybackService _voice;
  late final AudioPlayer _sfxPlayer;
  late final LocalStorageService _localStorage;
  Map<String, dynamic>? _pendingChapterResume;
  bool _restoredResumeThisLaunch = false;
  bool _resumeToastShown = false;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _startedAt = DateTime.now();
    _localStorage = ref.read(localStorageServiceProvider);
    _voice = VoicePlaybackService();
    _voice.init();
    _sfxPlayer = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
    _initSession();
  }

  @override
  void dispose() {
    _persistLearnResume();
    _sfxPlayer.dispose();
    _voice.dispose();
    super.dispose();
  }

  int _resolveChapterSize(int count) {
    if (count <= 12) return 6;
    if (count <= 30) return 8;
    if (count <= 60) return 10;
    return 12;
  }

  void _initSession() {
    final studySet = ref.read(studySetsProvider.notifier).getById(widget.setId);
    if (studySet == null || studySet.cards.isEmpty) return;

    _allCards = List<Flashcard>.of(studySet.cards);
    _cardById = {for (final c in _allCards) c.id: c};

    final chapterSize = _resolveChapterSize(_allCards.length);
    final allIds = _allCards.map((c) => c.id).toList();
    _chapterCardIds = <List<String>>[];
    for (var i = 0; i < allIds.length; i += chapterSize) {
      final end = min(i + chapterSize, allIds.length);
      _chapterCardIds.add(allIds.sublist(i, end));
    }
    _chapterCompleted = List<bool>.filled(_chapterCardIds.length, false);

    _restoreLearnResumeIfAvailable();
    _totalAttempts = 0;
    _totalCorrect = 0;
    _bestStreak = 0;
    _hintUsedTotal = 0;
    _startedAt = DateTime.now();
    _isInitialized = true;

    _initChapterSession();
  }

  void _restoreLearnResumeIfAvailable() {
    final resume = _localStorage.getLearnModeResume(widget.setId);
    if (resume == null) {
      _chapterIndex = 0;
      _pendingChapterResume = null;
      return;
    }

    final savedTotal = (resume['totalChapters'] as num?)?.toInt();
    if (savedTotal != _chapterCardIds.length) {
      _chapterIndex = 0;
      _pendingChapterResume = null;
      return;
    }

    final rawCompleted = resume['chapterCompleted'];
    if (rawCompleted is List) {
      final restored = rawCompleted
          .map((e) => e == true)
          .toList()
          .take(_chapterCompleted.length)
          .toList();
      for (var i = 0; i < restored.length; i++) {
        _chapterCompleted[i] = restored[i];
      }
    }

    final savedIndex = (resume['chapterIndex'] as num?)?.toInt() ?? 0;
    final firstIncomplete = _chapterCompleted.indexWhere((v) => !v);
    final fallbackIndex = firstIncomplete == -1 ? 0 : firstIncomplete;
    _chapterIndex = savedIndex.clamp(0, _chapterCardIds.length - 1);
    if (_chapterCompleted.every((v) => v)) {
      _chapterIndex = 0;
    } else if (_chapterCompleted[_chapterIndex]) {
      _chapterIndex = fallbackIndex;
    }
    final rawSession = resume['chapterSession'];
    _pendingChapterResume = rawSession is Map
        ? Map<String, dynamic>.from(rawSession)
        : null;
  }

  List<String> get _activeChapterIds {
    if (_chapterCardIds.isEmpty) return const <String>[];
    return _chapterCardIds[_chapterIndex];
  }

  void _initChapterSession() {
    final active = _activeChapterIds;

    _stageByCardId
      ..clear()
      ..addEntries(active.map((id) => MapEntry(id, 0)));
    _wrongCountByCardId
      ..clear()
      ..addEntries(active.map((id) => MapEntry(id, 0)));

    _queue
      ..clear()
      ..addAll(active);
    _queue.shuffle(_random);

    _attempts = 0;
    _correct = 0;
    _streak = 0;
    _consecutiveWrong = 0;
    _rescueQuestionsLeft = 0;
    _hintUsedOnCurrentQuestion = false;
    _chapterCheckpointShown = false;
    _rescueAppliedForCurrentCard = _rescueQuestionsLeft > 0;
    if (_rescueAppliedForCurrentCard) {
      _rescueQuestionsLeft--;
    }
    _selectedOption = null;
    _turnFeedbackVisible = false;
    _questionSeedCardId = null;
    _questionSeedRescueMode = null;
    _questionSeedType = null;
    _questionSeedDirection = null;
    _choiceSeedCardId = null;
    _choiceSeedDirection = null;
    _choiceSeedOptions = <Flashcard>[];
    _currentDirection = _LearnDirection.termToDefinition;
    _currentCardId = _queue.isNotEmpty ? _queue.first : null;
    _restorePendingChapterResumeIfPossible(active);

    if (mounted) setState(() {});
    _showResumeRestoredToastIfNeeded();
    _persistLearnResume();
  }

  void _showResumeRestoredToastIfNeeded() {
    if (!_restoredResumeThisLaunch || _resumeToastShown || !mounted) return;
    _resumeToastShown = true;
    final chapterNo = _chapterIndex + 1;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppFeedbackToast.show(
        context,
        message: '已恢復上次進度（第 $chapterNo 章）',
        tone: AppToastTone.success,
      );
    });
  }

  void _restorePendingChapterResumeIfPossible(List<String> active) {
    final raw = _pendingChapterResume;
    _pendingChapterResume = null;
    if (raw == null || active.isEmpty) return;

    final savedChapterIndex = (raw['chapterIndex'] as num?)?.toInt();
    if (savedChapterIndex != _chapterIndex) return;

    final savedActiveRaw = raw['activeCardIds'];
    if (savedActiveRaw is! List) return;
    final savedActive = savedActiveRaw.map((e) => '$e').toList();
    if (savedActive.length != active.length) return;
    for (var i = 0; i < active.length; i++) {
      if (savedActive[i] != active[i]) return;
    }

    final queueRaw = raw['queue'];
    if (queueRaw is! List) return;
    final restoredQueue = queueRaw
        .map((e) => '$e')
        .where((id) => _cardById.containsKey(id))
        .toList();
    final activeSet = active.toSet();
    restoredQueue.removeWhere((id) => !activeSet.contains(id));
    if (restoredQueue.isEmpty) return;

    _queue
      ..clear()
      ..addAll(restoredQueue);

    void restoreIntMap(Map<String, int> target, Object? rawValue) {
      if (rawValue is! Map) return;
      for (final id in active) {
        final value = (rawValue[id] as num?)?.toInt() ?? target[id] ?? 0;
        target[id] = value;
      }
    }

    restoreIntMap(_stageByCardId, raw['stageByCardId']);
    restoreIntMap(_wrongCountByCardId, raw['wrongCountByCardId']);

    _attempts = (raw['attempts'] as num?)?.toInt() ?? _attempts;
    _correct = (raw['correct'] as num?)?.toInt() ?? _correct;
    _totalAttempts = (raw['totalAttempts'] as num?)?.toInt() ?? _totalAttempts;
    _totalCorrect = (raw['totalCorrect'] as num?)?.toInt() ?? _totalCorrect;
    _streak = (raw['streak'] as num?)?.toInt() ?? _streak;
    _bestStreak = (raw['bestStreak'] as num?)?.toInt() ?? _bestStreak;
    _consecutiveWrong =
        (raw['consecutiveWrong'] as num?)?.toInt() ?? _consecutiveWrong;
    _rescueQuestionsLeft =
        (raw['rescueQuestionsLeft'] as num?)?.toInt() ?? _rescueQuestionsLeft;
    _hintUsedTotal = (raw['hintUsedTotal'] as num?)?.toInt() ?? _hintUsedTotal;

    final savedCurrentCardId = raw['currentCardId'] as String?;
    if (savedCurrentCardId != null && _queue.contains(savedCurrentCardId)) {
      _currentCardId = savedCurrentCardId;
      if (_queue.isNotEmpty && _queue.first != savedCurrentCardId) {
        _queue
          ..remove(savedCurrentCardId)
          ..insert(0, savedCurrentCardId);
      }
    } else {
      _currentCardId = _queue.firstOrNull;
    }
    _restoredResumeThisLaunch = true;
  }

  _LearnQuestionType _questionTypeFor(String cardId, bool rescueMode) {
    if (rescueMode) return _LearnQuestionType.multipleChoice;
    if (_activeChapterIds.length < 4) return _LearnQuestionType.textInput;
    final stage = _stageByCardId[cardId] ?? 0;
    if (stage <= 0) return _LearnQuestionType.multipleChoice;
    if (stage == 1) {
      return _random.nextBool()
          ? _LearnQuestionType.textInput
          : _LearnQuestionType.multipleChoice;
    }
    return _LearnQuestionType.textInput;
  }

  _LearnQuestionType _questionTypeForSeededDirection(
    String cardId,
    bool rescueMode,
    _LearnDirection direction,
  ) {
    final base = _questionTypeFor(cardId, rescueMode);

    // Definition free-text answers are often ambiguous (multiple meanings/POS).
    // Keep text input for spelling recall (definition -> term) only.
    if (base == _LearnQuestionType.textInput &&
        direction == _LearnDirection.termToDefinition) {
      return _LearnQuestionType.multipleChoice;
    }
    return base;
  }

  _LearnDirection _directionFor(String cardId, bool rescueMode) {
    if (rescueMode) return _LearnDirection.termToDefinition;
    final stage = _stageByCardId[cardId] ?? 0;
    if (stage <= 0) return _LearnDirection.termToDefinition;
    return _random.nextBool()
        ? _LearnDirection.termToDefinition
        : _LearnDirection.definitionToTerm;
  }

  List<Flashcard> _choicesFor(
    Flashcard correctCard,
    _LearnDirection direction,
  ) {
    final activeSet = _activeChapterIds.toSet();
    final others =
        _allCards
            .where((c) => c.id != correctCard.id && activeSet.contains(c.id))
            .toList()
          ..shuffle(_random);

    if (direction == _LearnDirection.definitionToTerm) {
      others.sort((a, b) {
        final da = (a.definition.length - correctCard.definition.length).abs();
        final db = (b.definition.length - correctCard.definition.length).abs();
        return da.compareTo(db);
      });
    } else {
      others.sort((a, b) {
        final da = (a.term.length - correctCard.term.length).abs();
        final db = (b.term.length - correctCard.term.length).abs();
        return da.compareTo(db);
      });
    }

    final fallback = _allCards.where((c) => c.id != correctCard.id).toList()
      ..shuffle(_random);
    while (others.length < 3 && fallback.isNotEmpty) {
      final candidate = fallback.removeLast();
      if (!others.any((c) => c.id == candidate.id)) {
        others.add(candidate);
      }
    }

    final selected = <Flashcard>[correctCard, ...others.take(3)]
      ..shuffle(_random);
    return selected;
  }

  Future<void> _advance(bool isCorrect) async {
    if (_currentCardId == null) return;
    final cardId = _currentCardId!;

    _attempts++;
    _totalAttempts++;
    if (isCorrect) {
      _correct++;
      _totalCorrect++;
      _streak++;
      _consecutiveWrong = 0;
      if (_streak > _bestStreak) _bestStreak = _streak;
    } else {
      _streak = 0;
      _consecutiveWrong++;
      _wrongCountByCardId[cardId] = (_wrongCountByCardId[cardId] ?? 0) + 1;
      if (_consecutiveWrong >= 2) {
        final wasRescueInactive = _rescueQuestionsLeft <= 0;
        _rescueQuestionsLeft = max(_rescueQuestionsLeft, 2);
        if (wasRescueInactive) {
          _showFloatingTip('切換成救援模式啦，先幫你把節奏抓回來，穩的！', color: AppTheme.orange);
        }
      }
    }

    final currentStage = _stageByCardId[cardId] ?? 0;
    final canAdvanceMastery = isCorrect && !_hintUsedOnCurrentQuestion;
    final nextStage = canAdvanceMastery
        ? currentStage + 1
        : (isCorrect ? currentStage : 0);
    _stageByCardId[cardId] = nextStage.clamp(0, _masteryStage);
    _trackOutcomeWrite(
      _recordLearnOutcome(
        cardId: cardId,
        isCorrect: isCorrect,
        stageBefore: currentStage,
        stageAfter: _stageByCardId[cardId] ?? 0,
        hintUsed: _hintUsedOnCurrentQuestion,
        rescueMode: _rescueAppliedForCurrentCard,
      ),
    );

    if (_queue.isNotEmpty && _queue.first == cardId) {
      _queue.removeAt(0);
    } else {
      _queue.remove(cardId);
    }

    if ((_stageByCardId[cardId] ?? 0) < _masteryStage) {
      if (isCorrect) {
        final stage = _stageByCardId[cardId] ?? 0;
        final gap = 2 + (stage * 2) + _random.nextInt(2);
        final insertAt = gap.clamp(0, _queue.length);
        _queue.insert(insertAt, cardId);
      } else {
        final wrongCount = _wrongCountByCardId[cardId] ?? 1;
        final insertAt = min(1 + (wrongCount % 3), _queue.length);
        _queue.insert(insertAt, cardId);
      }
    }

    if (_queue.isEmpty) {
      _chapterCompleted[_chapterIndex] = true;
      _persistLearnResume();
      if (_chapterIndex < _chapterCardIds.length - 1) {
        _showChapterComplete();
      } else {
        _clearLearnResume();
        _showResult();
      }
      return;
    }

    final masteredNow = _stageByCardId.values
        .where((v) => v >= _masteryStage)
        .length;
    final chapterTarget = (_activeChapterIds.length / 2).ceil();
    if (!_chapterCheckpointShown && masteredNow >= chapterTarget) {
      _chapterCheckpointShown = true;
      _showFloatingTip('進度 Checkpoint！這章已經過半了，繼續衝一波！');
    }

    if (isCorrect && (_streak == 3 || _streak == 5)) {
      _showFloatingTip(
        _streak == 5 ? '五連殺！手感燙到不行，直接把這章刷掉！' : '三連勝，節奏帶起來了喔！',
        color: AppTheme.green,
      );
    }

    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!mounted) return;
    setState(() {
      _rescueAppliedForCurrentCard = _rescueQuestionsLeft > 0;
      if (_rescueAppliedForCurrentCard) {
        _rescueQuestionsLeft--;
      }
      _hintUsedOnCurrentQuestion = false;
      _selectedOption = null;
      _turnFeedbackVisible = false;
      _currentCardId = _queue.first;
      _questionSeedCardId = null;
      _questionSeedRescueMode = null;
      _questionSeedType = null;
      _questionSeedDirection = null;
      _choiceSeedCardId = null;
      _choiceSeedDirection = null;
      _choiceSeedOptions = <Flashcard>[];
    });
  }

  void _showChapterComplete() {
    unawaited(_flushOutcomeInvalidations());
    final next = _chapterIndex + 2;
    final total = _chapterCardIds.length;
    final completedAfterThis = _chapterCompleted.where((v) => v).length;
    final overallChapterPercent = total == 0
        ? 0
        : ((completedAfterThis / total) * 100).round().clamp(0, 100);
    final chapterAccuracy = _attempts == 0
        ? 0
        : (_correct / _attempts * 100).round().clamp(0, 100);
    final nextChapterCount = _chapterCardIds[_chapterIndex + 1].length;
    final estimateMinutes = max(1, (nextChapterCount * 0.6).round());
    final accuracyLine = chapterAccuracy >= 85
        ? '太神啦，這章根本送分題！'
        : chapterAccuracy >= 65
        ? '有料喔，下一章繼續保持這節奏。'
        : '不哭不哭，下一章我們先放慢腳步穩穩吃。';

    showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'chapter_complete',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final fade = CurvedAnimation(parent: animation, curve: Curves.easeOut);
        final scale = Tween<double>(begin: 0.95, end: 1.0).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
        );
        return FadeTransition(
          opacity: fade,
          child: ScaleTransition(
            scale: scale,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: AppTheme.green.withValues(alpha: 0.22),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 18,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  color: AppTheme.green.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: const Icon(
                                  Icons.emoji_events_rounded,
                                  color: AppTheme.green,
                                  size: 28,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '第 ${_chapterIndex + 1} 章 破關啦',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w900,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      accuracyLine,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.outline,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.green.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: _buildChapterDialogStat(
                                    label: '本章正確率',
                                    value: '$chapterAccuracy%',
                                    color: AppTheme.green,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _buildChapterDialogStat(
                                    label: '整體刷題進度',
                                    value: '$overallChapterPercent%',
                                    color: AppTheme.indigo,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.indigo.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: AppTheme.indigo.withValues(alpha: 0.16),
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(
                                  Icons.lock_open_rounded,
                                  color: AppTheme.indigo,
                                  size: 18,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '下一章：第 $next/$total 章（$nextChapterCount 張卡）\n大概要花 $estimateMinutes 分鐘，喝口水再上！',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    _initChapterSession();
                                  },
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                  ),
                                  child: const Text('再刷一次這章'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    setState(() {
                                      _chapterIndex++;
                                    });
                                    _initChapterSession();
                                  },
                                  style: FilledButton.styleFrom(
                                    backgroundColor: AppTheme.green,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.arrow_forward_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('前進下一關'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showResult() {
    unawaited(_flushOutcomeInvalidations());
    final l10n = AppLocalizations.of(context);
    final accuracy = _totalAttempts == 0
        ? 0
        : (_totalCorrect / _totalAttempts * 100).round().clamp(0, 100);
    final elapsedSeconds = DateTime.now().difference(_startedAt).inSeconds;
    final accent = accuracy >= 80 ? AppTheme.green : AppTheme.orange;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            StudyResultHeader(
              accentColor: accent,
              icon: accuracy >= 80
                  ? Icons.school_rounded
                  : Icons.auto_graph_rounded,
              title: '刷題闖關完成',
              primaryText: '$accuracy%',
              badgeText: '${_allCards.length} 張卡片',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                StudyResultChip(
                  label: '答對',
                  value: '$_totalCorrect/$_totalAttempts',
                  color: AppTheme.green,
                ),
                StudyResultChip(
                  label: '時間',
                  value: '${elapsedSeconds}s',
                  color: AppTheme.indigo,
                ),
                StudyResultChip(
                  label: '最高連擊',
                  value: '$_bestStreak',
                  color: AppTheme.orange,
                ),
                StudyResultChip(
                  label: '提示',
                  value: '$_hintUsedTotal',
                  color: AppTheme.indigo,
                ),
                StudyResultChip(
                  label: '章節',
                  value:
                      '${_chapterCompleted.where((v) => v).length}/${_chapterCardIds.length}',
                  color: AppTheme.green,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              EncouragementLines.pick(accuracy),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            StudyResultDialogActions(
              leftLabel: l10n.tryAgain,
              rightLabel: l10n.done,
              onLeft: () {
                Navigator.pop(context);
                _clearLearnResume();
                unawaited(_flushOutcomeInvalidations());
                _initSession();
              },
              onRight: () {
                _clearLearnResume();
                unawaited(_flushOutcomeInvalidations());
                Navigator.pop(context);
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showChapterPicker() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _chapterCardIds.length,
            itemBuilder: (context, index) {
              final chapterNum = index + 1;
              final count = _chapterCardIds[index].length;
              final completed = _chapterCompleted[index];
              final selected = index == _chapterIndex;
              return ListTile(
                leading: Icon(
                  completed ? Icons.check_circle : Icons.menu_book_rounded,
                  color: completed ? AppTheme.green : null,
                ),
                title: Text('第 $chapterNum 章'),
                subtitle: Text('$count 張卡片'),
                trailing: selected
                    ? const Icon(Icons.play_arrow_rounded)
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _chapterIndex = index;
                  });
                  _initChapterSession();
                },
              );
            },
          ),
        );
      },
    );
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

    if (studySet == null || studySet.cards.length < 2) {
      return Scaffold(
        appBar: AppBar(
          leading: const AppBackButton(),
          title: const Text('刷題闖關'),
        ),
        body: Center(child: Text(l10n.needAtLeast2Cards)),
      );
    }

    if (!_isInitialized || _currentCardId == null) {
      return Scaffold(
        appBar: AppBar(
          leading: const AppBackButton(),
          title: const Text('刷題闖關'),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final currentCard = _cardById[_currentCardId]!;
    final rescueModeForCurrent = _rescueAppliedForCurrentCard;
    final type = _resolveSeededQuestionType(
      currentCard.id,
      rescueModeForCurrent,
    );
    _currentDirection = _resolveSeededDirection(
      currentCard.id,
      rescueModeForCurrent,
    );

    final chapterMastered = _stageByCardId.values
        .where((v) => v >= _masteryStage)
        .length;
    final chapterTotal = _activeChapterIds.length;
    final chapterProgress = chapterTotal == 0
        ? 0.0
        : chapterMastered / chapterTotal;

    final weakCount = _stageByCardId.values.where((v) => v == 0).length;
    final chapterMood = _chapterMoodLine(
      chapterProgress: chapterProgress,
      weakCount: weakCount,
    );
    _showCoachNoticeIfNeeded(
      chapterProgress: chapterProgress,
      rescueMode: _rescueQuestionsLeft > 0,
      weakCount: weakCount,
    );
    _checkProgressMilestone(chapterProgress);
    _autoPlayPromptForCurrent(currentCard, type);

    return Scaffold(
      appBar: AppBar(
        leading: const AppBackButton(),
        title: Text('刷題闖關｜第 ${_chapterIndex + 1}/${_chapterCardIds.length} 章'),
        actions: [
          IconButton(
            icon: const Icon(Icons.view_list_rounded),
            onPressed: _showChapterPicker,
            tooltip: '章節清單',
          ),
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
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildStageHeader(
                      chapterProgress: chapterProgress,
                      weakCount: weakCount,
                      chapterMood: chapterMood,
                      glowActive: _progressGlowActive,
                    ),
                    const SizedBox(height: 14),
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(
                        begin: 0,
                        end: chapterProgress.clamp(0.0, 1.0),
                      ),
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, child) {
                        return Transform.scale(
                          scaleY: 1.6,
                          alignment: Alignment.centerLeft,
                          child: RoundedProgressBar(value: value),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 90),
                    curve: Curves.easeOut,
                    transform: Matrix4.translationValues(
                      _questionCardShakeX,
                      0,
                      0,
                    ),
                    child: AnimatedScale(
                      scale: _questionCardScale,
                      duration: const Duration(milliseconds: 130),
                      curve: Curves.easeOutCubic,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                        decoration: AppTheme.softCardDecoration(
                          fillColor: Colors.white,
                          borderRadius: 20,
                          borderColor: AppTheme.indigo.withValues(alpha: 0.24),
                          elevation: 2,
                        ),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, animation) {
                            final offset = Tween<Offset>(
                              begin: const Offset(0.02, 0),
                              end: Offset.zero,
                            ).animate(animation);
                            return FadeTransition(
                              opacity: animation,
                              child: SlideTransition(
                                position: offset,
                                child: child,
                              ),
                            );
                          },
                          child: KeyedSubtree(
                            key: ValueKey(
                              'q_${currentCard.id}_${type.name}_${_currentDirection.name}',
                            ),
                            child: type == _LearnQuestionType.multipleChoice
                                ? _buildMultipleChoice(currentCard)
                                : _buildTextInput(currentCard),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 18,
            child: IgnorePointer(
              ignoring: !_turnFeedbackVisible,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutBack,
                offset: _turnFeedbackVisible
                    ? Offset.zero
                    : const Offset(0, 0.25),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: _turnFeedbackVisible ? 1 : 0,
                  child: _buildTurnFeedbackBar(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMultipleChoice(Flashcard card) {
    if (_choiceSeedCardId != card.id ||
        _choiceSeedOptions.isEmpty ||
        _choiceSeedDirection != _currentDirection) {
      _choiceSeedCardId = card.id;
      _choiceSeedDirection = _currentDirection;
      _choiceSeedOptions = _choicesFor(card, _currentDirection);
    }

    final askDefinition = _currentDirection == _LearnDirection.termToDefinition;
    final prompt = askDefinition ? card.term : card.definition;
    final options = _choiceSeedOptions;
    final correctIndex = options.indexWhere((c) => c.id == card.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          askDefinition ? '看到這個單字，你想到什麼？' : '這個意思的英文怎麼拼？',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                prompt,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _buildPromptAudioIconButton(
              promptText: prompt,
              tooltip: askDefinition ? '重播單字' : '重播題目',
            ),
          ],
        ),
        const SizedBox(height: 20),
        ...List.generate(options.length, (i) {
          QuizOptionState state = QuizOptionState.normal;
          if (_selectedOption != null) {
            if (i == correctIndex) {
              state = QuizOptionState.correct;
            } else if (i == _selectedOption) {
              state = QuizOptionState.incorrect;
            }
          }
          return QuizOptionTile(
            text: askDefinition ? options[i].definition : options[i].term,
            state: state,
            onTap: _selectedOption == null
                ? () async {
                    final isCorrect = i == correctIndex;
                    setState(() => _selectedOption = i);
                    await _showTurnFeedbackThenAdvance(
                      isCorrect: isCorrect,
                      card: card,
                    );
                  }
                : null,
          );
        }),
      ],
    );
  }

  Widget _buildTextInput(Flashcard card) {
    final askDefinition = _currentDirection == _LearnDirection.termToDefinition;
    final prompt = askDefinition ? card.term : card.definition;
    final answer = askDefinition ? card.definition : card.term;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextInputQuestion(
          key: ValueKey(
            'learn_text_${card.id}_${_stageByCardId[card.id]}_${askDefinition ? 'td' : 'dt'}',
          ),
          definition: prompt,
          correctAnswer: answer,
          exactMatch: true, // 現行填空題一律精確比對，避免誤套容錯率
          headerTrailing: _buildPromptAudioIconButton(
            promptText: prompt,
            tooltip: askDefinition ? '重播單字' : '重播題目',
          ),
          enableHint: true,
          maxHints: 2,
          onHintUsed: (_) {
            _hintUsedOnCurrentQuestion = true;
            _hintUsedTotal++;
          },
          hintBuilder: (answer, usedHints) {
            final trimmed = answer.trim();
            if (trimmed.isEmpty) return '';
            final example = card.exampleSentence.trim();

            if (usedHints == 1 && example.isNotEmpty) {
              var exampleHint = example;
              if (!askDefinition) {
                final escaped = RegExp.escape(trimmed);
                exampleHint = exampleHint.replaceAll(
                  RegExp(escaped, caseSensitive: false),
                  '____',
                );
              }
              return '例句提示：$exampleHint';
            }

            // Skip POS-like prefixes so hints reveal meaningful content first.
            final normalized = trimmed.replaceAll(RegExp(r'\s+'), ' ');
            final posPrefixMatch = RegExp(
              r'^(?:[\(\[]?\s*(?:n|v|adj|adv|prep|pron|conj|int|aux|art|det)\.?\s*[\)\]]?\s*[,，、:：-]?\s*)+',
              caseSensitive: false,
            ).firstMatch(normalized);
            final startIndex = posPrefixMatch?.end ?? 0;
            final contentPart = normalized.substring(startIndex).trimLeft();
            final base = contentPart.isEmpty ? normalized : contentPart;

            final reveal = min(base.length, usedHints * 2);
            final head = base.substring(0, reveal);
            if (reveal >= base.length) {
              return startIndex > 0 ? '提示：內容是 $head' : head;
            }
            return '提示：內容前面是 $head...';
          },
          onAnswered: (isCorrect) {
            _showTurnFeedbackThenAdvance(
              isCorrect: isCorrect,
              card: card,
              delay: const Duration(milliseconds: 900),
            );
          },
        ),
      ],
    );
  }

  Future<void> _speakText(String text) async {
    await _voice.speakMultiLingual(text, userInitiated: true);
  }

  Widget _buildPromptAudioIconButton({
    required String promptText,
    required String tooltip,
  }) {
    return IconButton(
      onPressed: () => _speakText(promptText),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        backgroundColor: AppTheme.indigo.withValues(alpha: 0.08),
        foregroundColor: AppTheme.indigo,
      ),
      icon: const Icon(Icons.volume_up_rounded, size: 20),
    );
  }

  Widget _buildStageHeader({
    required double chapterProgress,
    required int weakCount,
    required String chapterMood,
    required bool glowActive,
  }) {
    final chapterPercent = (chapterProgress * 100).round();
    final accent = weakCount >= 3 ? AppTheme.orange : AppTheme.green;
    final chapterMastered = _stageByCardId.values
        .where((v) => v >= _masteryStage)
        .length;
    final chapterTotal = _activeChapterIds.length;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppTheme.indigo.withValues(alpha: 0.14),
            accent.withValues(alpha: 0.10),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.indigo.withValues(alpha: 0.18)),
        boxShadow: glowActive
            ? [
                BoxShadow(
                  color: AppTheme.green.withValues(alpha: 0.16),
                  blurRadius: 18,
                  spreadRadius: 1,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '第 ${_chapterIndex + 1} 章｜$chapterMood',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '$chapterPercent%',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: AppTheme.indigo,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '\u5DF2\u638C\u63E1 $chapterMastered/$chapterTotal',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  String _chapterMoodLine({
    required double chapterProgress,
    required int weakCount,
  }) {
    if (chapterProgress >= 0.85) return '準備收尾';
    if (_streak >= 5) return '手感很熱';
    if (weakCount >= max(2, (_activeChapterIds.length / 3).round())) {
      return '先穩基本盤';
    }
    if (chapterProgress >= 0.4) return '漸入佳境';
    return '暖身起步';
  }

  void _autoPlayPromptForCurrent(Flashcard card, _LearnQuestionType type) {
    final askDefinition = _currentDirection == _LearnDirection.termToDefinition;
    final prompt = askDefinition ? card.term : card.definition;
    final key = '${card.id}_${_currentDirection.name}_${type.name}';
    if (_lastAutoSpeakKey == key) return;
    _lastAutoSpeakKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _voice.speakMultiLingual(prompt, userInitiated: false);
    });
  }

  int _chapterProgressPercent(double value) =>
      ((value * 100).round().clamp(0, 100) as num).toInt();

  _LearnQuestionType _resolveSeededQuestionType(
    String cardId,
    bool rescueMode,
  ) {
    final shouldReseed =
        _questionSeedCardId != cardId || _questionSeedRescueMode != rescueMode;
    if (shouldReseed ||
        _questionSeedType == null ||
        _questionSeedDirection == null) {
      _questionSeedCardId = cardId;
      _questionSeedRescueMode = rescueMode;
      _questionSeedDirection = _directionFor(cardId, rescueMode);
      _questionSeedType = _questionTypeForSeededDirection(
        cardId,
        rescueMode,
        _questionSeedDirection!,
      );
    }
    return _questionSeedType!;
  }

  _LearnDirection _resolveSeededDirection(String cardId, bool rescueMode) {
    final shouldReseed =
        _questionSeedCardId != cardId || _questionSeedRescueMode != rescueMode;
    if (shouldReseed ||
        _questionSeedDirection == null ||
        _questionSeedType == null) {
      _questionSeedCardId = cardId;
      _questionSeedRescueMode = rescueMode;
      _questionSeedDirection = _directionFor(cardId, rescueMode);
      _questionSeedType = _questionTypeForSeededDirection(
        cardId,
        rescueMode,
        _questionSeedDirection!,
      );
    }
    return _questionSeedDirection!;
  }

  void _showFloatingTip(String message, {Color? color}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 1500),
        behavior: SnackBarBehavior.floating,
        backgroundColor: color,
      ),
    );
  }

  void _showCoachNoticeIfNeeded({
    required double chapterProgress,
    required bool rescueMode,
    required int weakCount,
  }) {
    String? key;
    String? message;

    if (rescueMode) {
      key = 'coach_rescue_${_chapterIndex}_${_currentCardId ?? ''}';
      message = '教練廣播：啟動救援模式！這幾題先放水，幫你找回手感。';
    } else if (chapterProgress >= 0.8) {
      key = 'coach_final_$_chapterIndex';
      message = '教練廣播：這章快打完了，穩住就贏了！';
    } else if (_streak >= 4) {
      key = 'coach_streak_${_chapterIndex}_${_streak ~/ 2}';
      message = '教練廣播：氣勢正旺喔！這幾題要不要挑戰盲解（不看提示）？';
    } else if (weakCount >= max(2, (_activeChapterIds.length / 3).round())) {
      key = 'coach_weak_$_chapterIndex';
      message = '教練廣播：先把容易卡關的單字救回來，別急，慢慢來比較快。';
    }

    if (key == null || message == null || key == _lastCoachNoticeKey) return;
    _lastCoachNoticeKey = key;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showFloatingTip(message!, color: AppTheme.indigo);
    });
  }

  Future<void> _showTurnFeedbackThenAdvance({
    required bool isCorrect,
    required Flashcard card,
    Duration delay = const Duration(milliseconds: 700),
  }) async {
    _triggerQuestionCardPulse(isCorrect: isCorrect);
    final correctText = _currentDirection == _LearnDirection.termToDefinition
        ? card.definition
        : card.term;

    if (!mounted) return;
    setState(() {
      _turnFeedbackCorrect = isCorrect;
      _turnFeedbackTitle = isCorrect
          ? _pickPositiveFeedbackTitle(nextStreakPreview: _streak + 1)
          : _pickRetryFeedbackTitle();
      _turnFeedbackSubtitle = isCorrect
          ? _pickPositiveFeedbackSubtitle(nextStreakPreview: _streak + 1)
          : '正解：$correctText';
      _turnFeedbackVisible = true;
    });
    _playTurnSfx(isCorrect);

    await Future<void>.delayed(delay);
    if (!mounted) return;
    setState(() {
      _turnFeedbackVisible = false;
    });

    await Future<void>.delayed(const Duration(milliseconds: 90));
    if (!mounted) return;
    await _advance(isCorrect);
  }

  Widget _buildTurnFeedbackBar() {
    final color = _turnFeedbackCorrect
        ? const Color(0xFF16A34A)
        : const Color(0xFFF59E0B);
    final icon = _turnFeedbackCorrect
        ? Icons.check_circle_rounded
        : Icons.info_rounded;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _turnFeedbackTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _turnFeedbackSubtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChapterDialogStat({
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  String _pickPositiveFeedbackTitle({required int nextStreakPreview}) {
    if (nextStreakPreview >= 5) {
      const hotStreak = <String>['太神啦，火力全開！', '手感燙到不行，繼續衝', '這波超穩，直接帶走'];
      return hotStreak[_random.nextInt(hotStreak.length)];
    }
    const normal = <String>['水喔，答對了', '讚啦，這題拿下', '漂亮，繼續保持', '穩的，正解'];
    return normal[_random.nextInt(normal.length)];
  }

  String _pickPositiveFeedbackSubtitle({required int nextStreakPreview}) {
    if (nextStreakPreview >= 5) {
      const hot = <String>['節奏超好，這章直接給他秒掉', '維持這車速，本章馬上通關', '不要停，趁手感超燙把分數刷滿'];
      return hot[_random.nextInt(hot.length)];
    }
    if (nextStreakPreview >= 3) {
      const warm = <String>['連擊起來了，繼續往前推', '節奏對了，下一題也穩穩拿下', '讚讚，現在是拉開進度的大好時機'];
      return warm[_random.nextInt(warm.length)];
    }
    const early = <String>['先把穩定度練起來', '水喔，繼續把這章的手感暖開', '節奏正常發揮，下一題繼續'];
    return early[_random.nextInt(early.length)];
  }

  String _pickRetryFeedbackTitle() {
    const titles = <String>[
      '這題先記下來',
      '差一點點，下次討回來',
      '沒事，我們先把這題存起來',
      '先放著，等等再回來處理它',
    ];
    return titles[_random.nextInt(titles.length)];
  }

  Future<void> _playTurnSfx(bool isCorrect) async {
    try {
      await _sfxPlayer.stop();
      await _sfxPlayer.play(
        AssetSource(isCorrect ? 'sfx/correct.wav' : 'sfx/wrong.wav'),
        volume: isCorrect ? 0.98 : 1.0,
      );
      if (isCorrect) {
        HapticFeedback.lightImpact();
      } else {
        HapticFeedback.mediumImpact();
      }
    } catch (_) {}
  }

  void _persistLearnResume() {
    if (!_isInitialized) return;
    if (_chapterCardIds.isEmpty || _chapterCompleted.isEmpty) return;
    _localStorage.saveLearnModeResume(
      setId: widget.setId,
      chapterIndex: _chapterIndex,
      totalChapters: _chapterCardIds.length,
      chapterCompleted: List<bool>.from(_chapterCompleted),
      chapterSession: <String, dynamic>{
        'chapterIndex': _chapterIndex,
        'activeCardIds': List<String>.from(_activeChapterIds),
        'queue': List<String>.from(_queue),
        'currentCardId': _currentCardId,
        'stageByCardId': Map<String, int>.from(_stageByCardId),
        'wrongCountByCardId': Map<String, int>.from(_wrongCountByCardId),
        'attempts': _attempts,
        'correct': _correct,
        'totalAttempts': _totalAttempts,
        'totalCorrect': _totalCorrect,
        'streak': _streak,
        'bestStreak': _bestStreak,
        'consecutiveWrong': _consecutiveWrong,
        'rescueQuestionsLeft': _rescueQuestionsLeft,
        'hintUsedTotal': _hintUsedTotal,
      },
    );
  }

  void _clearLearnResume() {
    _localStorage.clearLearnModeResume(widget.setId);
  }

  Future<void> _recordLearnOutcome({
    required String cardId,
    required bool isCorrect,
    required int stageBefore,
    required int stageAfter,
    required bool hintUsed,
    required bool rescueMode,
  }) async {
    try {
      await ref
          .read(studyOutcomeRecorderProvider)
          .recordRating(
            cardId: cardId,
            setId: widget.setId,
            rating: _ratingForLearnOutcome(
              isCorrect: isCorrect,
              stageBefore: stageBefore,
              hintUsed: hintUsed,
            ),
            reviewType: 'learn',
            metadata: <String, dynamic>{
              'stageBefore': stageBefore,
              'stageAfter': stageAfter,
              'hintUsed': hintUsed,
              'rescueMode': rescueMode,
              'chapterIndex': _chapterIndex,
            },
          );
      _outcomesDirty = true;
    } catch (e) {
      debugPrint('Failed to record learn outcome: $e');
    }
  }

  void _trackOutcomeWrite(Future<void> future) {
    _pendingOutcomeWrites.add(future);
    unawaited(future.whenComplete(() => _pendingOutcomeWrites.remove(future)));
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

  int _ratingForLearnOutcome({
    required bool isCorrect,
    required int stageBefore,
    required bool hintUsed,
  }) {
    if (!isCorrect) return 1;
    if (hintUsed) return 2;
    if (stageBefore <= 0) return 2;
    if (stageBefore >= _masteryStage - 1 && _streak >= 5) return 4;
    return 3;
  }

  void _triggerQuestionCardPulse({required bool isCorrect}) {
    if (!mounted) return;
    final token = ++_questionCardAnimToken;
    if (isCorrect) {
      setState(() {
        _questionCardShakeX = 0;
        _questionCardScale = 1.006;
      });
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        if (!mounted || token != _questionCardAnimToken) return;
        setState(() {
          _questionCardScale = 1.0;
        });
      });
      return;
    }

    setState(() {
      _questionCardScale = 0.998;
      _questionCardShakeX = -4;
    });
    Future<void>.delayed(const Duration(milliseconds: 60), () {
      if (!mounted || token != _questionCardAnimToken) return;
      setState(() => _questionCardShakeX = 4);
    });
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (!mounted || token != _questionCardAnimToken) return;
      setState(() {
        _questionCardShakeX = 0;
        _questionCardScale = 1.0;
      });
    });
  }

  void _checkProgressMilestone(double chapterProgress) {
    final percent = _chapterProgressPercent(chapterProgress);
    final milestone = percent >= 100 ? 100 : (percent >= 50 ? 50 : 0);
    if (milestone == 0 || milestone == _lastChapterProgressMilestone) return;
    _lastChapterProgressMilestone = milestone;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _progressGlowActive = true;
      });
      Future<void>.delayed(const Duration(milliseconds: 420), () {
        if (!mounted) return;
        setState(() {
          _progressGlowActive = false;
        });
      });
    });
  }
}
