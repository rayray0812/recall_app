import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:recall_app/core/services/study_haptics.dart';
import 'package:recall_app/providers/session_xp_provider.dart';
import 'package:recall_app/features/study/widgets/combo_indicator.dart';
import 'package:recall_app/features/study/widgets/xp_toast.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:recall_app/models/flashcard.dart';
import 'package:recall_app/models/card_progress.dart';
import 'package:recall_app/providers/study_set_provider.dart';
import 'package:recall_app/features/study/widgets/quiz_option_tile.dart';
import 'package:recall_app/features/study/widgets/text_input_question.dart';
import 'package:recall_app/features/study/widgets/true_false_question.dart';
import 'package:recall_app/features/study/utils/part_of_speech.dart';
import 'package:recall_app/features/study/widgets/rounded_progress_bar.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/core/theme/app_theme.dart';
import 'package:recall_app/core/widgets/app_back_button.dart';
import 'package:recall_app/features/study/widgets/completion_celebrate_overlay.dart';
import 'package:recall_app/features/study/widgets/confusion_diagnosis_dialog.dart';
import 'package:recall_app/providers/local_ai_provider.dart';

enum QuizQuestionType { multipleChoice, textInput, trueFalse }

enum QuizDirection { termToDef, defToTerm, mixed }

class QuizSettings {
  final int questionCount;
  final Set<QuizQuestionType> enabledTypes;
  final QuizDirection direction;
  final bool prioritizeWeakCards;

  const QuizSettings({
    required this.questionCount,
    this.enabledTypes = const {
      QuizQuestionType.multipleChoice,
      QuizQuestionType.textInput,
      QuizQuestionType.trueFalse,
    },
    this.direction = QuizDirection.termToDef,
    this.prioritizeWeakCards = false,
  });
}

class QuizQuestion {
  final Flashcard card;
  final QuizQuestionType type;

  /// For multiple choice: 4 indices into [_allCards].
  final List<int> optionIndices;

  /// For true/false: the definition shown (may be wrong).
  final String shownDefinition;

  /// For true/false: whether [shownDefinition] is the correct definition.
  final bool isCorrectPair;

  /// Whether the question is reversed (definition→term instead of term→definition).
  final bool reversed;

  const QuizQuestion({
    required this.card,
    required this.type,
    this.optionIndices = const [],
    this.shownDefinition = '',
    this.isCorrectPair = true,
    this.reversed = false,
  });
}

/// AI-generated multiple-choice options for one question: [texts] are the 4
/// shuffled display strings and [correctIndex] points to the real answer.
class _SmartMcOptions {
  final List<String> texts;
  final int correctIndex;
  const _SmartMcOptions(this.texts, this.correctIndex);
}

/// Selects cards for the quiz, optionally weighted by SRS data.
///
/// When [prioritizeWeak] is true, cards with higher difficulty, more lapses,
/// overdue status, or that are new/learning get higher sampling weights.
List<Flashcard> selectQuizCards({
  required List<Flashcard> allCards,
  required int count,
  required Random random,
  bool prioritizeWeak = false,
  Map<String, CardProgress> progressMap = const {},
}) {
  if (!prioritizeWeak || progressMap.isEmpty) {
    final shuffled = List.of(allCards)..shuffle(random);
    return shuffled.take(min(count, shuffled.length)).toList();
  }

  final now = DateTime.now().toUtc();
  final weights = <double>[];

  for (final card in allCards) {
    double weight = 1.0;
    final progress = progressMap[card.id];

    if (progress == null) {
      // Never reviewed → weight 2.0
      weight = 2.0;
    } else {
      // Overdue cards
      if (progress.due != null && progress.due!.isBefore(now)) {
        weight += 3.0;
      }
      // High difficulty
      weight += 0.3 * progress.difficulty;
      // Many lapses
      weight += 0.5 * progress.lapses;
      // New or learning cards
      if (progress.state == 0) {
        weight += 1.5; // New
      } else if (progress.state == 1 || progress.state == 3) {
        weight += 1.0; // Learning / Relearning
      }
    }

    weights.add(weight);
  }

  // Weighted random sampling without replacement
  final selected = <Flashcard>[];
  final remaining = List.generate(allCards.length, (i) => i);
  final remainingWeights = List.of(weights);
  final targetCount = min(count, allCards.length);

  for (var i = 0; i < targetCount; i++) {
    final totalWeight = remainingWeights.fold(0.0, (a, b) => a + b);
    var roll = random.nextDouble() * totalWeight;
    int pickedIdx = remaining.length - 1;

    for (var j = 0; j < remaining.length; j++) {
      roll -= remainingWeights[j];
      if (roll <= 0) {
        pickedIdx = j;
        break;
      }
    }

    selected.add(allCards[remaining[pickedIdx]]);
    remaining.removeAt(pickedIdx);
    remainingWeights.removeAt(pickedIdx);
  }

  return selected;
}

class QuizScreen extends ConsumerStatefulWidget {
  final String setId;
  final int? questionCount;
  final QuizSettings? settings;

  const QuizScreen({
    super.key,
    required this.setId,
    this.questionCount,
    this.settings,
  });

  @override
  ConsumerState<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends ConsumerState<QuizScreen>
    with SingleTickerProviderStateMixin {
  final _random = Random();
  late final AnimationController _completionController;
  Timer? _advanceTimer;
  int _currentIndex = 0;
  int _score = 0;
  int? _selectedOption;
  List<Flashcard> _allCards = const [];
  List<QuizQuestion> _questions = const [];
  int _mainQuestionCount = 0;
  DateTime _sessionStartedAt = DateTime.now();
  DateTime _questionStartedAt = DateTime.now();
  final List<int> _wrongIndices = [];
  bool _isReinforcementRound = false;
  int _reinforcementScore = 0;
  int _paceDeltaPoints = 0;
  int _pacedQuestionCount = 0;
  bool _showCompletionCelebrate = false;
  bool _navigatingToResult = false;
  // AI smart-distractor enrichment. Cache is keyed by [_smartKey] (card + ask
  // direction) so options stay stable across rebuilds and are reused. When a
  // question's key is present, its AI options replace the random-card baseline.
  final Map<String, _SmartMcOptions> _smartCache = {};
  final Set<String> _smartInFlight = {};
  // True when the *current* answered question was scored against AI options
  // (so rendering keeps showing them and L3 diagnosis — which needs a real
  // distractor card — is suppressed).
  bool _answeredWithSmart = false;
  final _xpToastKey = GlobalKey<XpToastOverlayState>();

  String _smartKey(QuizQuestion q) => '${q.card.id}_${q.reversed}';

  QuizSettings get _effectiveSettings {
    if (widget.settings != null) return widget.settings!;
    return QuizSettings(questionCount: widget.questionCount ?? 999);
  }

  @override
  void initState() {
    super.initState();
    _completionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 920),
    );
    _initQuiz();
  }

  @override
  void dispose() {
    _advanceTimer?.cancel();
    _completionController.dispose();
    super.dispose();
  }

  void _initQuiz() {
    final studySet = ref.read(studySetsProvider.notifier).getById(widget.setId);
    if (studySet == null || studySet.cards.length < 4) return;

    _allCards = studySet.cards;
    final settings = _effectiveSettings;

    // Build progress map for SRS weighting
    Map<String, CardProgress> progressMap = {};
    if (settings.prioritizeWeakCards) {
      final storage = ref.read(localStorageServiceProvider);
      final progressList = storage.getCardProgressForSet(widget.setId);
      for (final p in progressList) {
        progressMap[p.cardId] = p;
      }
    }

    final selected = selectQuizCards(
      allCards: _allCards,
      count: settings.questionCount,
      random: _random,
      prioritizeWeak: settings.prioritizeWeakCards,
      progressMap: progressMap,
    );

    _questions = _generateMixedQuestions(selected, settings);
    _mainQuestionCount = _questions.length;
    _sessionStartedAt = DateTime.now();
    _questionStartedAt = DateTime.now();
    _currentIndex = 0;
    _score = 0;
    _selectedOption = null;
    _wrongIndices.clear();
    _isReinforcementRound = false;
    _reinforcementScore = 0;
    _paceDeltaPoints = 0;
    _pacedQuestionCount = 0;
    _showCompletionCelebrate = false;
    _navigatingToResult = false;
    _completionController.value = 0;
    // Defer AI prefetch until providers are ready (after first frame).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetchSmartForCurrent();
    });
  }

  List<QuizQuestion> _generateMixedQuestions(
    List<Flashcard> cards,
    QuizSettings settings,
  ) {
    final enabledTypes = settings.enabledTypes.toList();
    final questions = <QuizQuestion>[];

    for (var i = 0; i < cards.length; i++) {
      // Distribute types evenly from enabled types
      final type = enabledTypes[i % enabledTypes.length];

      // Determine direction
      bool reversed = false;
      switch (settings.direction) {
        case QuizDirection.termToDef:
          reversed = false;
          break;
        case QuizDirection.defToTerm:
          reversed = true;
          break;
        case QuizDirection.mixed:
          reversed = _random.nextBool();
          break;
      }

      questions.add(_buildQuestion(cards[i], type, reversed: reversed));
    }

    // Shuffle to avoid predictable type patterns
    questions.shuffle(_random);
    return questions;
  }

  QuizQuestion _buildQuestion(
    Flashcard card,
    QuizQuestionType type, {
    bool reversed = false,
  }) {
    switch (type) {
      case QuizQuestionType.multipleChoice:
        final correctIndex = _allCards.indexOf(card);
        final wrongIndices = List.generate(_allCards.length, (i) => i)
          ..remove(correctIndex)
          ..shuffle(_random);
        final optionIndices = [correctIndex, ...wrongIndices.take(3)]
          ..shuffle(_random);
        return QuizQuestion(
          card: card,
          type: type,
          optionIndices: optionIndices,
          reversed: reversed,
        );
      case QuizQuestionType.textInput:
        return QuizQuestion(card: card, type: type, reversed: reversed);
      case QuizQuestionType.trueFalse:
        final isCorrect = _random.nextBool();
        String shownDef;
        if (isCorrect) {
          shownDef = _stripPos(reversed ? card.term : card.definition);
        } else {
          final others = _allCards.where((c) => c.id != card.id).toList();
          others.shuffle(_random);
          shownDef = _stripPos(
            reversed ? others.first.term : others.first.definition,
          );
        }
        return QuizQuestion(
          card: card,
          type: type,
          shownDefinition: shownDef,
          isCorrectPair: isCorrect,
          reversed: reversed,
        );
    }
  }

  void _onMultipleChoiceSelect(int optionIndex) {
    if (_selectedOption != null) return;
    final question = _questions[_currentIndex];
    _applyPaceScore(question.type);

    // Prefer AI options if they arrived for this question; otherwise score
    // against the baseline random-card options.
    final smart = _smartCache[_smartKey(question)];
    final bool isCorrect;
    if (smart != null) {
      isCorrect = optionIndex == smart.correctIndex;
      _answeredWithSmart = true;
    } else {
      final correctIndex = _allCards.indexOf(question.card);
      isCorrect = question.optionIndices[optionIndex] == correctIndex;
    }

    setState(() {
      _selectedOption = optionIndex;
      if (isCorrect) {
        StudyHaptics.onCorrect();
        _isReinforcementRound ? _reinforcementScore++ : _score++;
        final earned = ref.read(sessionXpProvider.notifier).onCorrect();
        _xpToastKey.currentState?.showXp(earned);
      } else {
        StudyHaptics.onWrong();
        ref.read(sessionXpProvider.notifier).onIncorrect();
        if (!_isReinforcementRound) {
          _wrongIndices.add(_currentIndex);
        }
      }
    });

    // Keep the quiz moving by default. Wrong real-card distractors get a longer
    // pause so the learner can opt into local-AI diagnosis; tapping the CTA
    // cancels this timer and leaves the manual "Next" button visible.
    final offersDiagnosis =
        !isCorrect && !_isReinforcementRound && !_answeredWithSmart;
    _advanceAfterDelay(offersDiagnosis ? 3500 : 1200);
  }

  void _onTextInputAnswered(bool isCorrect) {
    _applyPaceScore(_questions[_currentIndex].type);
    if (isCorrect) {
      StudyHaptics.onCorrect();
      final earned = ref.read(sessionXpProvider.notifier).onCorrect();
      _xpToastKey.currentState?.showXp(earned);
    } else {
      StudyHaptics.onWrong();
      ref.read(sessionXpProvider.notifier).onIncorrect();
    }
    setState(() {
      if (isCorrect) {
        _isReinforcementRound ? _reinforcementScore++ : _score++;
      } else if (!_isReinforcementRound) {
        _wrongIndices.add(_currentIndex);
      }
    });

    _advanceAfterDelay(2000);
  }

  void _onTrueFalseAnswered(bool isCorrect) {
    _applyPaceScore(_questions[_currentIndex].type);
    if (isCorrect) {
      StudyHaptics.onCorrect();
      final earned = ref.read(sessionXpProvider.notifier).onCorrect();
      _xpToastKey.currentState?.showXp(earned);
    } else {
      StudyHaptics.onWrong();
      ref.read(sessionXpProvider.notifier).onIncorrect();
    }
    setState(() {
      if (isCorrect) {
        _isReinforcementRound ? _reinforcementScore++ : _score++;
      } else if (!_isReinforcementRound) {
        _wrongIndices.add(_currentIndex);
      }
    });

    _advanceAfterDelay(1200);
  }

  void _advanceAfterDelay(int ms) {
    _advanceTimer?.cancel();
    _advanceTimer = Timer(Duration(milliseconds: ms), _advance);
  }

  /// Moves to the next question / reinforcement round / results. Safe to call
  /// directly (e.g. from a manual "Next" button) — cancels any pending
  /// auto-advance timer first so the two paths can't double-fire.
  void _advance() {
    if (!mounted) return;
    _advanceTimer?.cancel();
    if (_currentIndex < _questions.length - 1) {
      setState(() {
        _currentIndex++;
        _selectedOption = null;
        _answeredWithSmart = false;
        _questionStartedAt = DateTime.now();
      });
      _prefetchSmartForCurrent();
    } else if (!_isReinforcementRound && _wrongIndices.isNotEmpty) {
      _startReinforcementRound();
    } else {
      _playCompletionCelebrateThenShowResults();
    }
  }

  /// Kick off AI distractor generation for the current multiple-choice question
  /// so options are likely ready by the time the learner reads it. No-op when
  /// the task isn't routed locally, already cached, or in flight. Falls back
  /// silently — the random-card baseline is always rendered until AI arrives.
  void _prefetchSmartForCurrent() {
    if (_currentIndex >= _questions.length) return;
    final q = _questions[_currentIndex];
    if (q.type != QuizQuestionType.multipleChoice) return;
    final key = _smartKey(q);
    if (_smartCache.containsKey(key) || _smartInFlight.contains(key)) return;
    if ((ref.read(smartDistractorsAvailableProvider).valueOrNull ?? false) ==
        false) {
      return;
    }
    _fetchSmartDistractors(q, key);
  }

  Future<void> _fetchSmartDistractors(QuizQuestion q, String key) async {
    _smartInFlight.add(key);
    final correctText = _stripPos(q.reversed ? q.card.term : q.card.definition);
    try {
      final distractors = await ref.read(
        smartDistractorsProvider(
          SmartDistractorRequest(
            cardId: q.card.id,
            term: q.card.term,
            definition: q.card.definition,
            correctOption: correctText,
            reversed: q.reversed,
          ),
        ).future,
      );
      if (!mounted || distractors == null || distractors.length < 3) return;
      if (_currentIndex >= _questions.length ||
          _smartKey(_questions[_currentIndex]) != key ||
          _selectedOption != null) {
        return;
      }
      final texts = [correctText, ...distractors.take(3)]..shuffle(_random);
      final correctIndex = texts.indexOf(correctText);
      _smartCache[key] = _SmartMcOptions(texts, correctIndex);
      setState(() {});
    } catch (_) {
      // Fail silent → keep baseline options.
    } finally {
      _smartInFlight.remove(key);
    }
  }

  Future<void> _playCompletionCelebrateThenShowResults() async {
    if (_showCompletionCelebrate || _navigatingToResult) return;
    setState(() {
      _showCompletionCelebrate = true;
    });
    await _completionController.forward(from: 0);
    if (!mounted) return;
    _showResults();
  }

  void _startReinforcementRound() {
    final wrongCards = _wrongIndices.map((i) => _questions[i].card).toList();
    setState(() {
      _isReinforcementRound = true;
      _reinforcementScore = 0;
      _questions = wrongCards
          .map((c) => _buildQuestion(c, QuizQuestionType.multipleChoice))
          .toList();
      _currentIndex = 0;
      _selectedOption = null;
      _answeredWithSmart = false;
      _questionStartedAt = DateTime.now();
    });
    _prefetchSmartForCurrent();
  }

  void _applyPaceScore(QuizQuestionType type) {
    final elapsedMs = DateTime.now()
        .difference(_questionStartedAt)
        .inMilliseconds;
    final targetMs = type == QuizQuestionType.textInput ? 7000 : 4000;
    _pacedQuestionCount++;
    _paceDeltaPoints += elapsedMs <= targetMs ? 1 : -1;
  }

  int _computePaceScore() {
    if (_pacedQuestionCount <= 0) return 50;
    final normalized =
        (_paceDeltaPoints + _pacedQuestionCount) / (_pacedQuestionCount * 2);
    return (normalized * 100).round().clamp(0, 100);
  }

  void _showResults() {
    if (_navigatingToResult) return;
    _navigatingToResult = true;
    final mainTotal = _mainQuestionCount;
    final mainScore = _score;
    final percent = mainTotal == 0
        ? 0
        : (mainScore / mainTotal * 100).round().clamp(0, 100);
    final elapsedSeconds = DateTime.now()
        .difference(_sessionStartedAt)
        .inSeconds;
    final paceScore = _computePaceScore();

    context.pushReplacement(
      '/study/${widget.setId}/quiz/result',
      extra: <String, dynamic>{
        'elapsedSeconds': elapsedSeconds,
        'score': mainScore,
        'total': mainTotal,
        'accuracy': percent,
        'paceScore': paceScore,
        'reinforcementScore': _isReinforcementRound ? _reinforcementScore : 0,
        'reinforcementTotal': _isReinforcementRound ? _questions.length : 0,
      },
    );
  }

  void _goHomeSmooth() {
    context.go('/');
  }

  // Helper to get prompt and answer based on reversed flag
  String _getPrompt(QuizQuestion q) =>
      q.reversed ? q.card.definition : q.card.term;
  String _getAnswer(QuizQuestion q) =>
      _stripPos(q.reversed ? q.card.term : q.card.definition);

  /// Strips common part-of-speech prefixes from text.
  /// e.g. "(n.) 蘋果" → "蘋果", "adj. 快樂的" → "快樂的"
  static final _posPattern = RegExp(
    r'^\s*\(?\s*(?:n|v|vt|vi|adj|adv|prep|conj|pron|int|det|aux|abbr|pl)\s*\.?\s*\)?\s*',
    caseSensitive: false,
  );
  String _stripPos(String text) {
    final stripped = text.replaceFirst(_posPattern, '').trim();
    return stripped.isEmpty ? text.trim() : stripped;
  }

  @override
  Widget build(BuildContext context) {
    final studySet = ref
        .watch(studySetsProvider)
        .where((s) => s.id == widget.setId)
        .firstOrNull;

    final l10n = AppLocalizations.of(context);

    if (studySet == null || studySet.cards.length < 4 || _questions.isEmpty) {
      return Scaffold(
        appBar: AppBar(leading: const AppBackButton(), title: Text(l10n.quiz)),
        body: Center(child: Text(l10n.needAtLeast4Cards)),
      );
    }

    final question = _questions[_currentIndex];
    final progress = (_currentIndex + 1) / _questions.length;

    return Scaffold(
      appBar: AppBar(
        leading: const AppBackButton(),
        title: Text(l10n.quiz),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: Text(
                '${_currentIndex + 1} / ${_questions.length}',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppTheme.green,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Center(
              child: Text(
                l10n.scoreLabel(
                  _isReinforcementRound ? _reinforcementScore : _score,
                ),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
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
              RoundedProgressBar(
                value: progress,
                counterText: '${_currentIndex + 1} / ${_questions.length}',
              ),
              if (_isReinforcementRound)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  decoration: AppTheme.softCardDecoration(
                    fillColor: Colors.white,
                    borderRadius: 12,
                    borderColor: AppTheme.cyan.withValues(alpha: 0.28),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.refresh_rounded,
                        size: 18,
                        color: AppTheme.cyan,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${l10n.reinforcementRound} \u2014 ${l10n.reinforcementDesc}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: AppTheme.cyan,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                    decoration: AppTheme.softCardDecoration(
                      fillColor: Colors.white,
                      borderRadius: 16,
                      borderColor: AppTheme.indigo.withValues(alpha: 0.24),
                    ),
                    child: _buildQuestionBody(question, l10n),
                  ),
                ),
              ),
            ],
          ),
          // Combo indicator
          const Positioned(top: 60, right: 16, child: ComboIndicator()),
          // XP toast
          Positioned(
            top: 100,
            left: 0,
            right: 0,
            child: Center(child: XpToastOverlay(key: _xpToastKey)),
          ),
          if (_showCompletionCelebrate)
            Positioned.fill(
              child: IgnorePointer(
                child: CompletionCelebrateOverlay(
                  animation: _completionController,
                  color: AppTheme.green,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildQuestionBody(QuizQuestion question, AppLocalizations l10n) {
    switch (question.type) {
      case QuizQuestionType.multipleChoice:
        return _buildMultipleChoice(question, l10n);
      case QuizQuestionType.textInput:
        return _buildTextInput(question, l10n);
      case QuizQuestionType.trueFalse:
        return _buildTrueFalse(question);
    }
  }

  Widget _buildPosChips(List<String> posTags) {
    if (posTags.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        children: posTags
            .map(
              (tag) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.indigo.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  tag,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.indigo,
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _buildMultipleChoice(QuizQuestion question, AppLocalizations l10n) {
    final correctIndex = _allCards.indexOf(question.card);
    final prompt = _getPrompt(question);
    final posTags = extractPartOfSpeechTags(question.card.tags);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          question.reversed ? l10n.whatIsTermFor : l10n.whatIsDefinitionOf,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          prompt,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        _buildPosChips(posTags),
        const SizedBox(height: 32),
        ..._buildOptionTiles(question, correctIndex),
        if (_shouldOfferDiagnosis(question, correctIndex))
          _buildDiagnosisRow(question, correctIndex, l10n),
      ],
    );
  }

  /// Builds the four option tiles, preferring AI smart distractors when they
  /// arrived for this question and otherwise the baseline random-card options.
  List<Widget> _buildOptionTiles(QuizQuestion question, int correctIndex) {
    final smart = _smartCache[_smartKey(question)];
    // Keep showing AI options once they're chosen (even after answering), but
    // never swap them in *after* the learner answered the baseline set.
    final useSmart =
        smart != null && (_selectedOption == null || _answeredWithSmart);

    if (useSmart) {
      return List.generate(smart.texts.length, (i) {
        QuizOptionState state = QuizOptionState.normal;
        if (_selectedOption != null) {
          if (i == smart.correctIndex) {
            state = QuizOptionState.correct;
          } else if (i == _selectedOption) {
            state = QuizOptionState.incorrect;
          }
        }
        return QuizOptionTile(
          text: smart.texts[i],
          state: state,
          onTap: _selectedOption == null
              ? () => _onMultipleChoiceSelect(i)
              : null,
        );
      });
    }

    return List.generate(4, (i) {
      final optionCardIndex = question.optionIndices[i];
      final optionCard = _allCards[optionCardIndex];

      QuizOptionState state = QuizOptionState.normal;
      if (_selectedOption != null) {
        if (optionCardIndex == correctIndex) {
          state = QuizOptionState.correct;
        } else if (i == _selectedOption) {
          state = QuizOptionState.incorrect;
        }
      }

      // Show answer side (definition or term) as option text, strip POS
      final optionText = _stripPos(
        question.reversed ? optionCard.term : optionCard.definition,
      );

      return QuizOptionTile(
        text: optionText,
        state: state,
        onTap: _selectedOption == null
            ? () => _onMultipleChoiceSelect(i)
            : null,
      );
    });
  }

  /// True when the learner just answered this multiple-choice question wrong in
  /// the main round with a real distractor card. The quiz still auto-advances,
  /// but the CTA can cancel that timer when the learner wants the explanation.
  bool _shouldOfferDiagnosis(QuizQuestion question, int correctIndex) {
    if (_selectedOption == null) return false;
    if (_isReinforcementRound) return false;
    // L3 needs a real distractor *card* (term + definition) to compare against;
    // AI string distractors don't map to a card, so skip diagnosis there.
    if (_answeredWithSmart) return false;
    final chosenCardIndex = question.optionIndices[_selectedOption!];
    return chosenCardIndex != correctIndex;
  }

  Widget _buildDiagnosisRow(
    QuizQuestion question,
    int correctIndex,
    AppLocalizations l10n,
  ) {
    final chosenCard = _allCards[question.optionIndices[_selectedOption!]];
    final targetCard = question.card;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: AppTheme.softCardDecoration(
          fillColor: AppTheme.indigo.withValues(alpha: 0.06),
          borderRadius: 14,
          borderColor: AppTheme.indigo.withValues(alpha: 0.16),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: () {
                  _advanceTimer?.cancel();
                  ConfusionDiagnosisDialog.show(
                    context,
                    request: ConfusionRequest(
                      targetTerm: targetCard.term,
                      targetDefinition: targetCard.definition,
                      chosenTerm: chosenCard.term,
                      chosenDefinition: chosenCard.definition,
                    ),
                  );
                },
                icon: Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.indigo.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Text('🧠', style: TextStyle(fontSize: 15)),
                ),
                label: Text(
                  l10n.confusionWhyCta,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.indigo,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _advance,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              child: Text(l10n.next),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextInput(QuizQuestion question, AppLocalizations l10n) {
    final prompt = _getPrompt(question);
    final answer = _getAnswer(question);
    final posTags = extractPartOfSpeechTags(question.card.tags);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          question.reversed ? l10n.whatIsTermFor : l10n.whatIsDefinitionOf,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
        _buildPosChips(posTags),
        const SizedBox(height: 16),
        TextInputQuestion(
          key: ValueKey('text_${question.card.id}_$_currentIndex'),
          definition: prompt,
          correctAnswer: answer,
          exactMatch: true, // 現行填空題一律精確比對，避免誤套容錯率
          onAnswered: _onTextInputAnswered,
        ),
      ],
    );
  }

  Widget _buildTrueFalse(QuizQuestion question) {
    final prompt = _getPrompt(question);
    final posTags = extractPartOfSpeechTags(question.card.tags);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPosChips(posTags),
        if (posTags.isNotEmpty) const SizedBox(height: 8),
        TrueFalseQuestion(
          key: ValueKey('tf_${question.card.id}_$_currentIndex'),
          term: prompt,
          shownDefinition: question.shownDefinition,
          isCorrectPair: question.isCorrectPair,
          onAnswered: _onTrueFalseAnswered,
        ),
      ],
    );
  }
}
