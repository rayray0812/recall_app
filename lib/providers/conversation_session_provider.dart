import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/features/study/data/conversation_scenarios.dart';
import 'package:recall_app/features/study/models/conversation_transcript.dart';
import 'package:recall_app/features/study/models/conversation_turn_record.dart';
import 'package:recall_app/features/study/services/conversation_engine.dart';
import 'package:recall_app/features/study/services/conversation_prompts.dart';
import 'package:recall_app/features/study/services/conversation_scenario_validator.dart';
import 'package:recall_app/features/study/services/conversation_scorer.dart';
import 'package:recall_app/features/study/utils/vocabulary_tracker.dart';
import 'package:recall_app/features/study/utils/weak_term_selector.dart';
import 'package:recall_app/models/card_progress.dart';
import 'package:recall_app/models/review_log.dart';
import 'package:recall_app/models/review_session.dart';
import 'package:recall_app/providers/ai_provider_provider.dart';
import 'package:recall_app/providers/ai_runtime_provider.dart';
import 'package:recall_app/providers/auth_provider.dart';
import 'package:recall_app/providers/conversation_engine_provider.dart';
import 'package:recall_app/providers/fsrs_provider.dart';
import 'package:recall_app/providers/gemini_key_provider.dart';
import 'package:recall_app/providers/stats_provider.dart';
import 'package:recall_app/providers/study_set_provider.dart';
import 'package:recall_app/services/ai_task.dart';
import 'package:recall_app/services/gemini_service.dart';
import 'package:recall_app/services/outcome_adapter.dart';
import 'package:uuid/uuid.dart';

/// Parameters for creating a conversation session.
class ConversationSessionParams {
  final String setId;
  final int turns;
  final String difficulty;
  final String? scenarioId;

  const ConversationSessionParams({
    required this.setId,
    required this.turns,
    required this.difficulty,
    this.scenarioId,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationSessionParams &&
          setId == other.setId &&
          turns == other.turns &&
          difficulty == other.difficulty &&
          scenarioId == other.scenarioId;

  @override
  int get hashCode => Object.hash(setId, turns, difficulty, scenarioId);
}

final conversationSessionProvider =
    AutoDisposeAsyncNotifierProviderFamily<
      ConversationSessionNotifier,
      ConversationSessionState,
      ConversationSessionParams
    >(ConversationSessionNotifier.new);

class ConversationSessionNotifier
    extends
        AutoDisposeFamilyAsyncNotifier<
          ConversationSessionState,
          ConversationSessionParams
        > {
  static const int _maxUserInputLength = 300;
  static const int _maxSessionTokenBudget = 5000;

  // ignore: unused_field
  static const List<ConversationScenario> _localScenarioPool = kConversationScenarios;

  static const int _recentScenarioWindow = 10;
  static final List<String> _recentScenarioTitles = <String>[];

  ConversationEngine? _engine;
  late VocabularyTracker _vocab;
  int _consecutiveApiFailures = 0;
  int _rateLimitHitCount = 0;
  DateTime? _lastChatApiCallAt;
  DateTime? _lastSuggestionApiCallAt;
  int _chatMinGapMs = 1500;
  DateTime? _rateLimitCooldownUntil;
  Timer? _cooldownTicker;
  int _estimatedTotalTokens = 0;
  String _lastAiQuestionText = '';
  bool _hasPersistedSessionResult = false;
  final Map<String, List<SuggestedReplyData>> _suggestionCache = {};

  @override
  Future<ConversationSessionState> build(ConversationSessionParams arg) async {
    ref.onDispose(() {
      _cooldownTicker?.cancel();
      _cooldownTicker = null;
    });
    return const ConversationSessionState();
  }

  /// Initialize and start the conversation session.
  Future<void> startSession() async {
    final engine = ref.read(conversationEngineProvider);
    if (engine == null) {
      // No cloud provider key configured at all.
      state = AsyncData(const ConversationSessionState());
      return;
    }
    _engine = engine;
    // Still used for scenario generation, suggestions and scoring (these route
    // through Gemini for now; they degrade gracefully when the key is empty).
    final apiKey = ref.read(geminiKeyProvider);

    final studySet = ref.read(studySetsProvider.notifier).getById(arg.setId);
    if (studySet == null) {
      state = AsyncData(const ConversationSessionState());
      return;
    }

    final terms = studySet.cards
        .map((c) => c.term)
        .where((t) => t.isNotEmpty)
        .toList();
    final termToDefinition = <String, String>{};
    for (final card in studySet.cards) {
      final term = card.term.trim();
      final definition = card.definition.trim();
      if (term.isEmpty || definition.isEmpty) continue;
      termToDefinition.putIfAbsent(term, () => definition);
    }

    final targetCount = min(
      terms.length,
      _sessionTargetTermCount(arg.difficulty),
    );
    // Rank terms by FSRS weakness so the conversation drills the words the
    // learner actually struggles with (overdue / lapsed / hard / fragile),
    // instead of a random subset.
    final priorityOrder = _weaknessOrderedTerms(terms);
    _vocab = VocabularyTracker(
      allTerms: terms,
      allTermDefinitions: termToDefinition,
      maxTargetCount: targetCount,
      priorityOrder: priorityOrder,
    );
    if (_vocab.targetTerms.length == 2 &&
        _hasSemanticConflict(_vocab.targetTerms[0], _vocab.targetTerms[1])) {
      final keep = _vocab.targetTerms.first;
      _vocab = VocabularyTracker.withTerms(
        targetTerms: <String>[keep],
        termDefinitions: <String, String>{keep: termToDefinition[keep] ?? ''},
      );
    }

    ConversationScenario? selectedScenario;
    if (arg.scenarioId != null && arg.scenarioId!.isNotEmpty) {
      selectedScenario = kConversationScenarios.cast<ConversationScenario?>().firstWhere(
        (s) => s!.id == arg.scenarioId,
        orElse: () => null,
      );
    }
    final scenario = selectedScenario ?? await _pickScenarioForTerms(
      apiKey: apiKey,
      terms: _vocab.targetTerms,
      definitions: termToDefinition,
      difficulty: arg.difficulty,
    );
    _rememberScenarioTitle(scenario.title);

    // Reset state
    _consecutiveApiFailures = 0;
    _rateLimitHitCount = 0;
    _lastChatApiCallAt = null;
    _lastSuggestionApiCallAt = null;
    _chatMinGapMs = 1500;
    _rateLimitCooldownUntil = null;
    _cooldownTicker?.cancel();
    _cooldownTicker = null;
    _estimatedTotalTokens = 0;
    _lastAiQuestionText = '';
    _hasPersistedSessionResult = false;
    _suggestionCache.clear();

    state = AsyncData(
      ConversationSessionState(
        targetTerms: _vocab.targetTerms,
        scenarioTitle: scenario.title,
        scenarioTitleZh: scenario.titleZh,
        scenarioSetting: scenario.setting,
        scenarioSettingZh: scenario.settingZh,
        aiRole: scenario.aiRole,
        aiRoleZh: scenario.aiRoleZh,
        userRole: scenario.userRole,
        userRoleZh: scenario.userRoleZh,
        stages: scenario.stages,
        stagesZh: scenario.stagesZh,
        isAiTyping: true,
      ),
    );

    // Send first turn
    await _sendMessageToAi('', addToUi: false, isFirstTurn: true);
  }

  Future<ConversationScenario> _pickScenarioForTerms({
    required String apiKey,
    required List<String> terms,
    required Map<String, String> definitions,
    required String difficulty,
  }) async {
    final blockedTitles = List<String>.from(_recentScenarioTitles);
    final attemptTermLimits = <int>[8, 6, 4];
    for (final limit in attemptTermLimits) {
      try {
        final generated = await GeminiService.generateRandomScenario(
          apiKey: apiKey,
          difficulty: difficulty,
          terms: terms.take(limit).toList(),
          avoidTitles: blockedTitles,
        ).timeout(const Duration(milliseconds: 3000));
        if (generated != null &&
            isStructurallyValidScenario(
              generated,
              blockedTitles: blockedTitles,
            )) {
          return generated;
        }
      } catch (_) {
        // Try next attempt.
      }
    }
    return _buildDynamicScenarioFromTerms(terms: terms);
  }

  void _rememberScenarioTitle(String title) {
    final normalized = title.trim().toLowerCase();
    if (normalized.isEmpty) return;
    _recentScenarioTitles.removeWhere((t) => t == normalized);
    _recentScenarioTitles.add(normalized);
    if (_recentScenarioTitles.length > _recentScenarioWindow) {
      _recentScenarioTitles.removeRange(
        0,
        _recentScenarioTitles.length - _recentScenarioWindow,
      );
    }
  }

  ConversationScenario _buildDynamicScenarioFromTerms({
    required List<String> terms,
  }) {
    final pickedTerms = terms.take(2).toList();
    final focus = pickedTerms.isEmpty ? 'key terms' : pickedTerms.join(', ');
    final t1 = pickedTerms.isNotEmpty ? pickedTerms[0] : 'item';
    final t2 = pickedTerms.length > 1 ? pickedTerms[1] : 'detail';
    final profile = _inferScenarioProfile(pickedTerms);
    final stage1 = 'State what you need about $t1';
    final stage2 = 'Ask a follow-up using $t2';
    final stage3 = 'Confirm details and constraints';
    final stage4 = 'Make a clear decision';
    final stage5 = 'Close the conversation politely';
    final stage1Zh = '先說明你對 $t1 的需求';
    final stage2Zh = '再用 $t2 問一個延伸問題';
    final stage3Zh = '確認細節與限制條件';
    final stage4Zh = '做出明確決定';
    final stage5Zh = '禮貌結束對話';

    return ConversationScenario(
      title: '${profile.title} - $focus',
      titleZh: '${profile.titleZh}（$focus）',
      setting:
          '${profile.setting} Focus terms: $focus. Keep the conversation practical and specific.',
      settingZh: '${profile.settingZh} 聚焦單字：$focus。請讓對話具體且貼近真實情境。',
      aiRole: profile.aiRole,
      aiRoleZh: profile.aiRoleZh,
      userRole: profile.userRole,
      userRoleZh: profile.userRoleZh,
      stages: <String>[stage1, stage2, stage3, stage4, stage5],
      stagesZh: <String>[stage1Zh, stage2Zh, stage3Zh, stage4Zh, stage5Zh],
    );
  }

  _ScenarioProfile _inferScenarioProfile(List<String> terms) {
    final bag = terms.join(' ').toLowerCase();
    if (RegExp(
      r'(plan|data|sim|carrier|convert|gb|mb|roaming|contract)',
    ).hasMatch(bag)) {
      return const _ScenarioProfile(
        title: 'Mobile Plan Consultation',
        titleZh: '手機方案諮詢',
        setting:
            'You are at a telecom counter discussing mobile plan options, usage limits, and costs.',
        settingZh: '你在電信門市和店員討論手機方案、用量限制與費用。',
        aiRole: 'Telecom Staff',
        aiRoleZh: '電信門市人員',
        userRole: 'Customer',
        userRoleZh: '顧客',
      );
    }
    if (RegExp(
      r'(exchange|currency|rate|convert|usd|jpy|eur|twd)',
    ).hasMatch(bag)) {
      return const _ScenarioProfile(
        title: 'Currency Exchange Help',
        titleZh: '換匯諮詢',
        setting:
            'You are at a bank counter discussing exchange rates, fees, and conversion amounts.',
        settingZh: '你在銀行櫃台詢問匯率、手續費與換匯金額。',
        aiRole: 'Bank Staff',
        aiRoleZh: '銀行櫃員',
        userRole: 'Customer',
        userRoleZh: '顧客',
      );
    }
    if (RegExp(
      r'(translate|grammar|vocabulary|sentence|word|phrase)',
    ).hasMatch(bag)) {
      return const _ScenarioProfile(
        title: 'Language Practice Support',
        titleZh: '語言練習輔導',
        setting:
            'You are in a tutoring session practicing practical usage of key words in short dialogue.',
        settingZh: '你在家教練習情境中，用短對話實際使用關鍵單字。',
        aiRole: 'Tutor',
        aiRoleZh: '家教老師',
        userRole: 'Student',
        userRoleZh: '學生',
      );
    }
    return const _ScenarioProfile(
      title: 'Practical Daily Conversation',
      titleZh: '日常情境對話',
      setting:
          'You are in a practical daily-life conversation with clear needs, options, and decisions.',
      settingZh: '你在日常情境中進行對話，包含明確需求、選項比較與決策。',
      aiRole: 'Service Staff',
      aiRoleZh: '服務人員',
      userRole: 'Customer',
      userRoleZh: '顧客',
    );
  }

  /// Order [terms] weakest-first using this set's FSRS [CardProgress]. Returns
  /// the input order on any storage error so a session never fails to start.
  List<String> _weaknessOrderedTerms(List<String> terms) {
    try {
      final studySet = ref.read(studySetsProvider.notifier).getById(arg.setId);
      if (studySet == null) return terms;
      final storage = ref.read(localStorageServiceProvider);
      final progressById = <String, CardProgress>{
        for (final p in storage.getCardProgressForSet(arg.setId)) p.cardId: p,
      };
      final progressByTerm = <String, CardProgress>{};
      for (final card in studySet.cards) {
        final term = card.term.trim();
        final progress = progressById[card.id];
        if (term.isNotEmpty && progress != null) {
          progressByTerm[term] = progress;
        }
      }
      return orderTermsByWeakness(
        terms: terms,
        progressByTerm: progressByTerm,
        now: DateTime.now().toUtc(),
      );
    } catch (_) {
      return terms;
    }
  }

  int _sessionTargetTermCount(String difficulty) {
    switch (difficulty.toLowerCase().trim()) {
      case 'easy':
        return 4;
      case 'hard':
        return 8;
      default:
        return 6;
    }
  }

  bool _hasSemanticConflict(String a, String b) {
    final left = a.toLowerCase().trim();
    final right = b.toLowerCase().trim();
    if (left.isEmpty || right.isEmpty) return false;
    final abstractCue = RegExp(
      r'(confidence|personality|mindset|emotion|motivation|belief|attitude|value)',
    );
    final concreteCue = RegExp(
      r'(price|item|ticket|drink|medicine|order|checkout|aisle|reservation|plan|data|contract)',
    );
    final aAbstract = abstractCue.hasMatch(left);
    final bAbstract = abstractCue.hasMatch(right);
    final aConcrete = concreteCue.hasMatch(left);
    final bConcrete = concreteCue.hasMatch(right);
    return (aAbstract && bConcrete) || (bAbstract && aConcrete);
  }

  /// Send user message and get AI response.
  Future<void> sendMessage(String text) async {
    _refreshCooldownState();
    final current = state.valueOrNull;
    if (current == null || current.isAiTyping || current.isSessionEnded) return;
    final sanitized = _sanitizeUserInput(text);
    if (sanitized.isEmpty) return;
    await _sendMessageToAi(sanitized, addToUi: true);
  }

  /// Generate reply suggestions.
  Future<void> generateSuggestions() async {
    _refreshCooldownState();
    final current = state.valueOrNull;
    if (current == null ||
        current.isAiTyping ||
        current.isSessionEnded ||
        current.isGeneratingSuggestions) {
      return;
    }

    if (current.isQuotaExhausted ||
        current.useLocalCoachOnly ||
        _isOverTokenBudget()) {
      _updateState(
        (s) => s.copyWith(suggestedReplies: _buildLocalSuggestedReplies()),
      );
      return;
    }
    if (_refreshCooldownState() || !_canUseRemoteSuggestion(current)) {
      _updateState(
        (s) => s.copyWith(suggestedReplies: _buildLocalSuggestedReplies()),
      );
      return;
    }

    final cacheKey = _suggestionCacheKey();
    final cached = _suggestionCache[cacheKey];
    if (cached != null && cached.isNotEmpty) {
      _updateState((s) => s.copyWith(suggestedReplies: cached));
      return;
    }

    final apiKey = ref.read(geminiKeyProvider);
    if (apiKey.isEmpty) return;

    _updateState((s) => s.copyWith(isGeneratingSuggestions: true));

    try {
      await _respectSuggestionRateLimit();
      final latestQuestion = _latestAiQuestion();
      final priorityTerms = _vocab.nextPriorityTerms();
      final suggestions = await GeminiService.generateSuggestedReplies(
        apiKey: apiKey,
        difficulty: arg.difficulty,
        scenarioTitle: state.valueOrNull?.scenarioTitle ?? '',
        aiRole: state.valueOrNull?.aiRole ?? '',
        userRole: state.valueOrNull?.userRole ?? '',
        latestQuestion: latestQuestion,
        priorityTerms: priorityTerms,
      );
      final mapped = suggestions
          .map(
            (s) => SuggestedReplyData(
              reply: s.reply,
              zhHint: s.zhHint,
              focusWord: s.focusWord,
            ),
          )
          .toList();
      _suggestionCache[cacheKey] = mapped;
      _updateState(
        (s) => s.copyWith(
          suggestedReplies: mapped,
          isGeneratingSuggestions: false,
          suggestionApiCalls: s.suggestionApiCalls + 1,
        ),
      );
    } catch (_) {
      _updateState((s) => s.copyWith(isGeneratingSuggestions: false));
    }
  }

  /// End session and write review logs.
  Future<void> endSession() async {
    final current = state.valueOrNull;
    if (current == null) return;
    _updateState((s) => s.copyWith(isSessionEnded: true));
    await _writeReviewLogs();
  }

  /// Update voice state from UI callback.
  void updateVoiceState(String stateName, String diagnostic) {
    _updateState(
      (s) => s.copyWith(voiceStateName: stateName, voiceDiagnostic: diagnostic),
    );
  }

  // ??? Private helpers ???

  Future<void> _sendMessageToAi(
    String text, {
    required bool addToUi,
    bool isFirstTurn = false,
  }) async {
    _refreshCooldownState();
    final current = state.valueOrNull;
    if (current == null || _engine == null) return;
    if (current.isSessionEnded) return;

    // Last-resort offline coach when budget/cooldown is exhausted.
    if (current.isQuotaExhausted ||
        current.useLocalCoachOnly ||
        _isOverTokenBudget()) {
      if (addToUi) _addUserMessage(text);
      _appendLocalCoachTurn(userText: text);
      return;
    }
    if (_refreshCooldownState() || !_canUseRemoteChat(current)) {
      if (addToUi) _addUserMessage(text);
      _appendLocalCoachTurn(userText: text);
      return;
    }

    // Snapshot history BEFORE adding the current user message, so it isn't sent
    // twice (once in history, once as userMessage).
    final history = _engineHistory();
    final systemPrompt = _currentSystemPrompt();
    final userMessage = buildTurnUserMessage(
      isFirstTurn: isFirstTurn,
      aiRole: current.aiRole,
      studentText: text,
    );

    if (addToUi) {
      final usedNow = _vocab.extractUsedTerms(text);
      if (usedNow.isNotEmpty) _vocab.practicedTerms.addAll(usedNow);
      _addUserMessage(text);
    }
    _updateState(
      (s) => s.copyWith(
        isAiTyping: true,
        suggestedReplies: [],
        practicedTerms: Set<String>.from(_vocab.practicedTerms),
      ),
    );

    try {
      await _respectChatRateLimit();
      // Each AI turn is a metered cloud call (§2.6). Atomically check + consume
      // one unit; if the daily quota is spent, degrade gracefully to the local
      // coach — same path as a rate-limit/quota engine error. NOTE: on failover
      // the engine may call >1 provider but this counts as one product unit (see
      // docs §2.6 — provider-attempt accounting is a known follow-up).
      final quota = ref.read(aiQuotaServiceProvider);
      final entitlement = ref.read(aiEntitlementProvider);
      if (!await quota.tryConsume(entitlement, AiTaskType.conversationTurn)) {
        _handleEngineError(ScanFailureReason.quotaExceeded, text);
        return;
      }
      final responseText = await _engine!.generateTurn(
        systemPrompt: systemPrompt,
        history: history,
        userMessage: userMessage,
      );
      _estimatedTotalTokens +=
          _estimateTokensFromChars(systemPrompt.length + userMessage.length) +
          _estimateTokensFromChars(responseText.length);
      await _applyAiResponse(
        responseText: responseText,
        text: text,
        addToUi: addToUi,
      );
      _consecutiveApiFailures = 0;
      _chatMinGapMs = 1500;
    } on ConversationEngineException catch (e) {
      _handleEngineError(e.reason, text);
    } catch (_) {
      _handleEngineError(ScanFailureReason.unknown, text);
    }
  }

  /// Conversation history as engine messages (UI bubbles → user/assistant roles).
  List<ConversationMessage> _engineHistory() {
    final msgs = state.valueOrNull?.messages ?? const <ChatMessageData>[];
    return [
      for (final m in msgs) ConversationMessage(isUser: !m.isAi, text: m.text),
    ];
  }

  /// Fresh system prompt for the current turn (folds in adaptive difficulty).
  String _currentSystemPrompt() {
    final s = state.valueOrNull;
    return buildConversationSystemPrompt(
      aiRole: s?.aiRole ?? '',
      userRole: s?.userRole ?? '',
      scenarioTitle: s?.scenarioTitle ?? '',
      scenarioSetting: s?.scenarioSetting ?? '',
      difficulty: arg.difficulty,
      targetWords: _vocab.targetTerms,
      totalTurns: arg.turns,
      currentTurn: s?.currentTurn ?? 0,
      adaptiveHint: _adaptDifficultyHint(),
    );
  }

  Future<void> _applyAiResponse({
    required String responseText,
    required String text,
    required bool addToUi,
  }) async {
    final aiText = cleanAiTurnText(
      responseText,
      aiRole: state.valueOrNull?.aiRole ?? '',
    );
    if (aiText.isEmpty) {
      _updateState((s) => s.copyWith(isAiTyping: false));
      return;
    }

    final messages = List<ChatMessageData>.from(
      state.valueOrNull?.messages ?? [],
    );
    messages.add(ChatMessageData(isAi: true, text: aiText));
    _lastAiQuestionText = aiText;

    final newTurn = (state.valueOrNull?.currentTurn ?? 0) + 1;
    final turnRecords = List<ConversationTurnRecord>.from(
      state.valueOrNull?.turnRecords ?? [],
    );

    if (addToUi) {
      turnRecords.add(
        ConversationTurnRecord(
          turnIndex: newTurn - 1,
          aiQuestion: aiText,
          userResponse: text,
          replyHint: '',
          termsUsed: _vocab.extractUsedTerms(text),
          timestamp: DateTime.now().toUtc(),
          isEvaluating: true,
        ),
      );
    }

    final isEnded = newTurn >= arg.turns;
    _updateState(
      (s) => s.copyWith(
        messages: messages,
        turnRecords: turnRecords,
        isAiTyping: false,
        latestReplyHint: '',
        currentTurn: newTurn,
        chatApiCalls: s.chatApiCalls + 1,
        isSessionEnded: isEnded,
      ),
    );

    if (addToUi) {
      // Fire-and-forget: scoring runs in the background and updates the turn.
      unawaited(_evaluateTurnAsync(newTurn - 1, aiText, text));
    }
    if (isEnded) {
      await _writeReviewLogs();
    }
  }

  /// Handle an engine failure (all configured providers exhausted): cool down on
  /// rate limits, then fall back to the offline coach for this turn.
  void _handleEngineError(ScanFailureReason reason, String userText) {
    _updateState((s) => s.copyWith(isAiTyping: false));
    if (reason == ScanFailureReason.quotaExceeded) {
      _startRateCooldown();
      final permanent = _rateLimitHitCount >= 3;
      _updateState(
        (s) => s.copyWith(
          useLocalCoachOnly: true,
          isQuotaExhausted: permanent ? true : s.isQuotaExhausted,
        ),
      );
    } else {
      _consecutiveApiFailures++;
      if (_consecutiveApiFailures >= 2) {
        _updateState((s) => s.copyWith(useLocalCoachOnly: true));
      }
    }
    _appendLocalCoachTurn(userText: userText);
  }

  void _addUserMessage(String text) {
    final messages = List<ChatMessageData>.from(
      state.valueOrNull?.messages ?? [],
    );
    messages.add(ChatMessageData(isAi: false, text: text));
    _updateState((s) => s.copyWith(messages: messages));
  }

  void _appendLocalCoachTurn({required String userText}) {
    final current = state.valueOrNull;
    if (current == null || current.isSessionEnded) return;

    final step = current.stages.isEmpty
        ? 'continue the conversation'
        : current.stages[current.currentTurn % current.stages.length];
    // Use more aggressive rotation: double the word count to expose more terms
    final baseWordCount = VocabularyTracker.targetTermsPerTurn(arg.difficulty);
    final wordCount = min(baseWordCount + 1, _vocab.targetTerms.length);
    final focus = _vocab.nextPriorityTerms(count: wordCount);
    // Advance by extra step to rotate through unpracticed terms faster
    _vocab.advanceFocusCursor(wordCount + 1);
    final lead = focus.isEmpty ? 'this situation' : focus.first;
    final extra = focus.length > 1 ? focus[1] : '';
    final third = focus.length > 2 ? focus[2] : '';

    // Look up definitions for contextual hints
    final leadDef = _vocab.termDefinitions[lead]?.trim() ?? '';
    final defContext = leadDef.isNotEmpty
        ? ' ($lead means: ${leadDef.length > 20 ? '${leadDef.substring(0, 20)}...' : leadDef})'
        : '';

    final aiRole = current.aiRole.isNotEmpty ? current.aiRole : 'the other person';
    final easyTemplates = [
      'At this point, what $lead do you want?$defContext',
      'What would you say about $lead now?$defContext',
      'How would you ask for $lead politely?$defContext',
      'What question would you ask $aiRole about $lead?$defContext',
      'Can you describe what you need regarding $lead?$defContext',
      if (extra.isNotEmpty)
        'Can you use $lead or $extra in a sentence?$defContext',
    ];
    final mediumTemplates = [
      'In this moment, what do you want to ask about $lead?$defContext',
      'How would you continue with $lead in this situation?$defContext',
      'What would your next sentence about $lead be?$defContext',
      'How would you explain your preference for $lead to $aiRole?$defContext',
      'What follow-up question about $lead would you ask?$defContext',
      if (extra.isNotEmpty)
        'Try to mention both $lead and $extra in your answer.$defContext',
      if (extra.isNotEmpty)
        'Compare $lead and $extra — which do you prefer and why?$defContext',
    ];
    final hardTemplates = [
      'Given this step, how would you justify your choice about $lead?$defContext',
      'How would you ask about $lead while mentioning ${extra.isEmpty ? 'one concern' : extra}?$defContext',
      'What would you say next to move this conversation forward about $lead?$defContext',
      'How would you negotiate with $aiRole about $lead?$defContext',
      'Explain your reasoning about $lead in detail.$defContext',
      if (extra.isNotEmpty)
        'How do $lead and $extra relate to your decision?$defContext',
      if (third.isNotEmpty)
        'Try to connect $lead, $extra, and $third in one response.$defContext',
    ];

    final templates = switch (arg.difficulty.toLowerCase().trim()) {
      'easy' => easyTemplates,
      'hard' => hardTemplates,
      _ => mediumTemplates,
    };
    var question = templates[current.currentTurn % templates.length];
    question = '$question ($step)';
    if (userText.trim().isNotEmpty) {
      final clippedUser = userText.trim().length > 36
          ? '${userText.trim().substring(0, 36)}...'
          : userText.trim();
      question = 'You said "$clippedUser". Nice. $question';
    }
    if (question == _lastAiQuestionText) {
      question = '$question Also add ${extra.isEmpty ? 'one detail' : extra}.';
    }

    final leadHintWord = leadDef.isNotEmpty && leadDef.length <= 20
        ? ' ($leadDef)'
        : '';
    final hint = switch (arg.difficulty.toLowerCase().trim()) {
      'easy' => 'Start with "I need $lead$leadHintWord because ..."',
      'hard' =>
        'Start with "I\'d choose $lead$leadHintWord because ..., and ${extra.isEmpty ? 'it' : extra} ..."',
      _ => 'Start with "I want $lead$leadHintWord because ..."',
    };

    final messages = List<ChatMessageData>.from(current.messages);
    messages.add(ChatMessageData(isAi: true, text: question));
    _lastAiQuestionText = question;

    final newTurn = current.currentTurn + 1;

    // Record this turn
    final turnRecords = List<ConversationTurnRecord>.from(current.turnRecords);
    if (userText.trim().isNotEmpty) {
      final usedNow = _vocab.extractUsedTerms(userText);
      _vocab.practicedTerms.addAll(usedNow);
      turnRecords.add(
        ConversationTurnRecord(
          turnIndex: newTurn - 1,
          aiQuestion: question,
          userResponse: userText,
          replyHint: hint,
          termsUsed: usedNow,
          timestamp: DateTime.now().toUtc(),
          isEvaluating: true,
        ),
      );
      // For local coach, use offline evaluation
      _evaluateTurnOffline(newTurn - 1, userText);
    }

    final isEnded = newTurn >= arg.turns;
    _updateState(
      (s) => s.copyWith(
        messages: messages,
        turnRecords: turnRecords,
        latestReplyHint: hint,
        currentTurn: newTurn,
        isAiTyping: false,
        isSessionEnded: isEnded,
        practicedTerms: Set<String>.from(_vocab.practicedTerms),
      ),
    );

    if (isEnded) {
      _writeReviewLogs();
    }
  }

  /// Write ReviewLog entries for each turn record.
  /// Non-blocking AI scoring for a turn.
  Future<void> _evaluateTurnAsync(
    int turnIndex,
    String aiQuestion,
    String userResponse,
  ) async {
    final current = state.valueOrNull;
    final geminiKey = ref.read(geminiKeyProvider).trim();
    final groqKey = ref.read(groqKeyProvider).trim();
    if (current == null || (geminiKey.isEmpty && groqKey.isEmpty)) {
      _evaluateTurnOffline(turnIndex, userResponse);
      return;
    }

    // Cloud scoring is metered (§2.6); atomically check + consume one unit, and
    // fall back to offline scoring once the daily speaking-score quota is spent.
    final quota = ref.read(aiQuotaServiceProvider);
    final entitlement = ref.read(aiEntitlementProvider);
    if (!await quota.tryConsume(entitlement, AiTaskType.speakingScore)) {
      _evaluateTurnOffline(turnIndex, userResponse);
      return;
    }

    _scoreWithFallback(
      aiQuestion: aiQuestion,
      userResponse: userResponse,
      scenarioTitle: current.scenarioTitle,
      geminiKey: geminiKey,
      groqKey: groqKey,
    ).then((feedback) {
      _updateTurnFeedback(
        turnIndex,
        feedback ??
            ConversationScorer.evaluateOffline(
              userResponse: userResponse,
              targetTerms: _vocab.targetTerms,
              aiQuestion: aiQuestion,
            ),
      );
    }).catchError((_) {
      _evaluateTurnOffline(turnIndex, userResponse);
    });
  }

  /// Score a turn trying the user's preferred cloud provider first, then the
  /// other as fallback. Returns null if neither produced usable feedback.
  Future<TurnFeedback?> _scoreWithFallback({
    required String aiQuestion,
    required String userResponse,
    required String scenarioTitle,
    required String geminiKey,
    required String groqKey,
  }) async {
    Future<TurnFeedback?> gemini() => geminiKey.isEmpty
        ? Future.value(null)
        : ConversationScorer.evaluateTurn(
            apiKey: geminiKey,
            aiQuestion: aiQuestion,
            userResponse: userResponse,
            scenarioTitle: scenarioTitle,
            difficulty: arg.difficulty,
            targetTerms: _vocab.targetTerms,
          );
    Future<TurnFeedback?> groq() => groqKey.isEmpty
        ? Future.value(null)
        : ConversationScorer.evaluateTurnGroq(
            apiKey: groqKey,
            aiQuestion: aiQuestion,
            userResponse: userResponse,
            scenarioTitle: scenarioTitle,
            difficulty: arg.difficulty,
            targetTerms: _vocab.targetTerms,
          );

    final preferGroq = ref.read(aiProviderProvider) == AiProvider.groq;
    final order = preferGroq ? [groq, gemini] : [gemini, groq];
    for (final attempt in order) {
      final result = await attempt();
      if (result != null) return result;
    }
    return null;
  }

  /// Offline scoring fallback.
  void _evaluateTurnOffline(int turnIndex, String userResponse) {
    // Find the AI question for this turn to improve relevance scoring
    final current = state.valueOrNull;
    String aiQuestion = '';
    if (current != null) {
      for (final turn in current.turnRecords) {
        if (turn.turnIndex == turnIndex) {
          aiQuestion = turn.aiQuestion;
          break;
        }
      }
    }
    final feedback = ConversationScorer.evaluateOffline(
      userResponse: userResponse,
      targetTerms: _vocab.targetTerms,
      aiQuestion: aiQuestion,
    );
    _updateTurnFeedback(turnIndex, feedback);
  }

  /// Update a specific turn's feedback in state.
  void _updateTurnFeedback(int turnIndex, TurnFeedback feedback) {
    final current = state.valueOrNull;
    if (current == null) return;
    final updated = List<ConversationTurnRecord>.from(current.turnRecords);
    for (var i = 0; i < updated.length; i++) {
      if (updated[i].turnIndex == turnIndex) {
        updated[i] = updated[i].copyWith(
          feedback: feedback,
          isEvaluating: false,
        );
        break;
      }
    }
    _updateState((s) => s.copyWith(turnRecords: updated));
  }

  Future<void> _writeReviewLogs() async {
    final current = state.valueOrNull;
    if (current == null || current.turnRecords.isEmpty) return;
    if (_hasPersistedSessionResult) return;
    _hasPersistedSessionResult = true;
    try {
      final localStorage = ref.read(localStorageServiceProvider);
      final fsrsService = ref.read(fsrsServiceProvider);
      final studySet = ref.read(studySetsProvider.notifier).getById(arg.setId);
      final userId = ref.read(currentUserProvider)?.id ?? 'local';
      const uuid = Uuid();
      final now = DateTime.now().toUtc();

      // Create a ReviewSession record for this conversation
      final sessionId = uuid.v4();
      final scoredTurns = current.turnRecords
          .where((t) => t.feedback != null)
          .toList();
      final scoreAvg = scoredTurns.isEmpty
          ? null
          : scoredTurns.fold<double>(
                0,
                (sum, t) => sum + (t.feedback!.overallScore),
              ) /
              scoredTurns.length;

      final session = ReviewSession(
        id: sessionId,
        userId: userId,
        modality: 'conversation',
        startedAt: current.turnRecords.first.timestamp,
        endedAt: now,
        itemCount: current.turnRecords.length,
        completedCount: scoredTurns.length,
        scoreAvg: scoreAvg,
      );
      await localStorage.saveReviewSession(session);

      // Save ReviewLogs for each turn, linked to session
      for (final turn in current.turnRecords) {
        final score =
            turn.feedback?.overallScoreRounded ?? _heuristicScore(turn);

        final log = ReviewLog(
          id: uuid.v4(),
          cardId: 'conversation_turn_${turn.turnIndex}',
          setId: arg.setId,
          rating: score >= 4 ? 4 : (score >= 3 ? 3 : (score >= 2 ? 2 : 1)),
          state: 0,
          reviewedAt: turn.timestamp,
          reviewType: 'conversation',
          speakingScore: score,
          sessionId: sessionId,
        );
        await localStorage.saveReviewLog(log);
      }

      // OutcomeAdapter: schedule unused target terms via FsrsService
      if (studySet != null) {
        final termToCardId = <String, String>{};
        for (final card in studySet.cards) {
          final term = card.term.trim();
          if (term.isNotEmpty) termToCardId[term] = card.id;
        }

        final unusedTerms =
            _vocab.targetTerms.toSet().difference(_vocab.practicedTerms);
        for (final term in unusedTerms) {
          final cardId = termToCardId[term];
          if (cardId == null) continue;
          final progress = localStorage.getCardProgress(cardId);
          if (progress == null) continue;

          final action = OutcomeAdapter.resolve(
            ConversationOutcome.conversationUnusedTerm,
          );
          if (action is ApplyFsrsRating) {
            final result = fsrsService.reviewCard(progress, action.rating);
            await localStorage.saveCardProgress(result.progress);
            await localStorage.saveReviewLog(
              result.log.copyWith(
                reviewType: 'conversation',
                sessionId: sessionId,
              ),
            );
          }
        }
      }

      // Save transcript
      await _saveTranscript(current);

      // Invalidate stats so they pick up new logs
      ref.invalidate(allReviewLogsProvider);
    } catch (_) {
      _hasPersistedSessionResult = false;
      rethrow;
    }
  }

  Future<void> _saveTranscript(ConversationSessionState current) async {
    final localStorage = ref.read(localStorageServiceProvider);
    final studySet = ref.read(studySetsProvider.notifier).getById(arg.setId);
    final setTitle = studySet?.title ?? '';

    double totalScore = 0;
    int scoredCount = 0;
    final transcriptTurns = <TranscriptTurn>[];
    for (final turn in current.turnRecords) {
      final fb = turn.feedback;
      if (fb != null) {
        totalScore += fb.overallScore;
        scoredCount++;
      }
      transcriptTurns.add(
        TranscriptTurn(
          aiQuestion: turn.aiQuestion,
          userResponse: turn.userResponse,
          grammarScore: fb?.grammarScore ?? 0,
          vocabScore: fb?.vocabScore ?? 0,
          relevanceScore: fb?.relevanceScore ?? 0,
          correction: fb?.correction ?? '',
          termsUsed: turn.termsUsed.toList(),
        ),
      );
    }

    final transcript = ConversationTranscript(
      id: const Uuid().v4(),
      setId: arg.setId,
      setTitle: setTitle,
      scenarioTitle: current.scenarioTitle,
      difficulty: arg.difficulty,
      totalTurns: current.turnRecords.length,
      overallScore: scoredCount > 0 ? totalScore / scoredCount : 0,
      completedAt: DateTime.now().toUtc(),
      turns: transcriptTurns,
    );

    await localStorage.saveConversationTranscript(transcript);
  }

  int _heuristicScore(ConversationTurnRecord turn) {
    final targetPerTurn = VocabularyTracker.targetTermsPerTurn(arg.difficulty);
    final coverageRatio = targetPerTurn > 0
        ? turn.termsUsed.length / targetPerTurn
        : 0.0;
    return (coverageRatio * 4 + 1).round().clamp(1, 5);
  }

  void _updateState(
    ConversationSessionState Function(ConversationSessionState) updater,
  ) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(updater(current));
  }

  String _sanitizeUserInput(String text) {
    var sanitized = text.length > _maxUserInputLength
        ? text.substring(0, _maxUserInputLength)
        : text;
    sanitized = sanitized.replaceAll(RegExp(r'[\r\n]+'), ' ');
    sanitized = sanitized
        .replaceAll(
          RegExp(
            r'(system|instruction|ignore|forget)\s*:',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    return sanitized;
  }

  bool _isOverTokenBudget() => _estimatedTotalTokens >= _maxSessionTokenBudget;

  int _estimateTokensFromChars(int chars) =>
      chars <= 0 ? 0 : (chars / 4).ceil();

  bool _refreshCooldownState() {
    final until = _rateLimitCooldownUntil;
    var inCooldown = false;
    var secondsLeft = 0;
    var expiredNow = false;
    if (until != null) {
      final remainingMs = until.difference(DateTime.now()).inMilliseconds;
      if (remainingMs > 0) {
        inCooldown = true;
        secondsLeft = ((remainingMs + 999) / 1000).floor();
      } else {
        _rateLimitCooldownUntil = null;
        _cooldownTicker?.cancel();
        _cooldownTicker = null;
        _chatMinGapMs = 1500;
        expiredNow = true;
      }
    }
    final current = state.valueOrNull;
    if (current != null) {
      final shouldResumeRemote =
          expiredNow && current.useLocalCoachOnly && !current.isQuotaExhausted;
      final needUpdate =
          current.isInRateCooldown != inCooldown ||
          current.cooldownSecondsLeft != secondsLeft ||
          shouldResumeRemote;
      if (needUpdate) {
        _updateState(
          (s) => s.copyWith(
            isInRateCooldown: inCooldown,
            cooldownSecondsLeft: inCooldown ? secondsLeft : 0,
            useLocalCoachOnly: shouldResumeRemote ? false : s.useLocalCoachOnly,
          ),
        );
      }
    }
    return inCooldown;
  }

  bool _canUseRemoteChat(ConversationSessionState s) {
    final maxCalls = max(arg.turns + 2, 8);
    return s.chatApiCalls < maxCalls;
  }

  bool _canUseRemoteSuggestion(ConversationSessionState s) =>
      s.suggestionApiCalls < 2;

  void _startRateCooldown() {
    _rateLimitHitCount++;
    // Exponential backoff: 45s, 90s, 180s (cap at 180s)
    final cooldownSeconds = min(180, 45 * pow(2, _rateLimitHitCount - 1).toInt());
    _rateLimitCooldownUntil = DateTime.now().add(Duration(seconds: cooldownSeconds));
    _chatMinGapMs = min(10000, 5000 * _rateLimitHitCount);
    _cooldownTicker?.cancel();
    _cooldownTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final active = _refreshCooldownState();
      if (!active) {
        _cooldownTicker?.cancel();
        _cooldownTicker = null;
      }
    });
    _refreshCooldownState();
  }

  Future<void> _respectChatRateLimit() async {
    final now = DateTime.now();
    final last = _lastChatApiCallAt;
    if (last != null) {
      final gapMs = now.difference(last).inMilliseconds;
      if (gapMs < _chatMinGapMs) {
        await Future<void>.delayed(
          Duration(milliseconds: _chatMinGapMs - gapMs),
        );
      }
    }
    _lastChatApiCallAt = DateTime.now();
  }

  Future<void> _respectSuggestionRateLimit() async {
    final now = DateTime.now();
    final last = _lastSuggestionApiCallAt;
    if (last != null) {
      final gapMs = now.difference(last).inMilliseconds;
      if (gapMs < 3000) {
        await Future<void>.delayed(Duration(milliseconds: 3000 - gapMs));
      }
    }
    _lastSuggestionApiCallAt = DateTime.now();
  }

  String _latestAiQuestion() {
    final messages = state.valueOrNull?.messages ?? [];
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].isAi) return messages[i].text;
    }
    return 'Could you answer based on this scenario?';
  }

  String _suggestionCacheKey() {
    final q = _latestAiQuestion().toLowerCase().trim();
    final wordCount = VocabularyTracker.targetTermsPerTurn(arg.difficulty);
    final focus = _vocab.nextPriorityTerms(count: wordCount).join('|');
    return '$q::$focus::${arg.difficulty}';
  }

  List<SuggestedReplyData> _buildLocalSuggestedReplies() {
    final wordCount = VocabularyTracker.targetTermsPerTurn(arg.difficulty);
    final focus = _vocab.nextPriorityTerms(count: wordCount);
    final first = focus.isEmpty ? 'this option' : focus.first;
    final second = focus.length > 1 ? focus[1] : 'the details';
    return [
      SuggestedReplyData(
        reply: 'Could you help me with $first?',
        zhHint: '\u5148\u79AE\u8C8C\u958B\u5834',
        focusWord: first,
      ),
      SuggestedReplyData(
        reply: 'I\'d go with $first because it fits me better.',
        zhHint: '\u88DC\u4E00\u500B\u7C21\u77ED\u539F\u56E0',
        focusWord: first,
      ),
      SuggestedReplyData(
        reply: 'Do you also have $second, by any chance?',
        zhHint: '\u81EA\u7136\u8FFD\u554F\u5EF6\u4F38',
        focusWord: second,
      ),
    ];
  }

  /// Compute adaptive difficulty hint based on recent turn scores.
  /// Returns a prompt modifier string to append.
  String _adaptDifficultyHint() {
    final current = state.valueOrNull;
    if (current == null || current.turnRecords.isEmpty) return '';
    // Look at most recent 3 turns with feedback
    final recentWithFeedback = current.turnRecords
        .where((t) => t.feedback != null)
        .toList();
    if (recentWithFeedback.length < 2) return '';
    final recent = recentWithFeedback.length > 3
        ? recentWithFeedback.sublist(recentWithFeedback.length - 3)
        : recentWithFeedback;
    final avgScore = recent
            .map((t) => t.feedback!.overallScore)
            .reduce((a, b) => a + b) /
        recent.length;
    if (avgScore >= 4.5) {
      return '\nStudent is doing very well. Make this question slightly more challenging — use longer sentences or less common vocabulary.';
    }
    if (avgScore <= 2.0) {
      return '\nStudent is struggling. Simplify the question, use shorter sentences, and provide more scaffolding in the reply hint.';
    }
    return '';
  }

}

class _ScenarioProfile {
  final String title;
  final String titleZh;
  final String setting;
  final String settingZh;
  final String aiRole;
  final String aiRoleZh;
  final String userRole;
  final String userRoleZh;

  const _ScenarioProfile({
    required this.title,
    required this.titleZh,
    required this.setting,
    required this.settingZh,
    required this.aiRole,
    required this.aiRoleZh,
    required this.userRole,
    required this.userRoleZh,
  });
}

