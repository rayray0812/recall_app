import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:recall_app/features/study/data/conversation_scenarios.dart';
import 'package:recall_app/features/study/models/conversation_transcript.dart';
import 'package:recall_app/features/study/models/conversation_turn_record.dart';
import 'package:recall_app/features/study/services/conversation_scorer.dart';
import 'package:recall_app/features/study/utils/vocabulary_tracker.dart';
import 'package:recall_app/features/study/utils/weak_term_selector.dart';
import 'package:recall_app/models/card_progress.dart';
import 'package:recall_app/models/review_log.dart';
import 'package:recall_app/models/review_session.dart';
import 'package:recall_app/providers/auth_provider.dart';
import 'package:recall_app/providers/fsrs_provider.dart';
import 'package:recall_app/providers/gemini_key_provider.dart';
import 'package:recall_app/providers/stats_provider.dart';
import 'package:recall_app/providers/study_set_provider.dart';
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

  ChatSession? _chatSession;
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
  int _chatModelIndex = 0;
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
    final apiKey = ref.read(geminiKeyProvider);
    if (apiKey.isEmpty) {
      state = AsyncData(const ConversationSessionState());
      return;
    }

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
    _chatModelIndex = 0;
    _hasPersistedSessionResult = false;
    _suggestionCache.clear();

    _chatSession = GeminiService.startConversation(
      apiKey: apiKey,
      terms: _vocab.targetTerms,
      difficulty: arg.difficulty,
      totalTurns: arg.turns,
      scenarioTitle: scenario.title,
      scenarioSetting: scenario.setting,
      aiRole: scenario.aiRole,
      userRole: scenario.userRole,
      chatModel: _currentChatModel(),
    );

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
            _isValidGeneratedScenario(generated, terms, blockedTitles)) {
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

  bool _isNearDuplicateTitle(String title, List<String> blockedTitles) {
    final normalized = title.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    for (final blocked in blockedTitles) {
      final b = blocked.trim().toLowerCase();
      if (b.isEmpty) continue;
      if (normalized == b) return true;
      if (normalized.contains(b) || b.contains(normalized)) return true;
    }
    return false;
  }

  bool _scenarioMatchesTargetTerms(
    ConversationScenario scenario,
    List<String> terms,
  ) {
    if (terms.isEmpty) return true;
    final bag =
        '${scenario.title} ${scenario.setting} ${scenario.stages.join(' ')}'
            .toLowerCase();
    final normalizedTerms = terms
        .map((t) => t.trim().toLowerCase())
        .where((t) => t.length >= 2)
        .toSet();
    var directHits = 0;
    for (final term in normalizedTerms) {
      if (bag.contains(term)) directHits++;
    }

    // Hard gate: scenario text must directly mention enough target terms.
    final requiredHits = normalizedTerms.length >= 4 ? 3 : 2;
    return directHits >= requiredHits;
  }

  bool _isValidGeneratedScenario(
    ConversationScenario scenario,
    List<String> terms,
    List<String> blockedTitles,
  ) {
    if (_isNearDuplicateTitle(scenario.title, blockedTitles)) {
      return false;
    }
    if (scenario.title.trim().isEmpty ||
        scenario.setting.trim().isEmpty ||
        scenario.aiRole.trim().isEmpty ||
        scenario.userRole.trim().isEmpty) {
      return false;
    }
    if (!_scenarioMatchesTargetTerms(scenario, terms)) {
      return false;
    }
    if (_containsScenarioMetaText(scenario.title) ||
        _containsScenarioMetaText(scenario.setting) ||
        _containsScenarioMetaText(scenario.aiRole) ||
        _containsScenarioMetaText(scenario.userRole) ||
        scenario.stages.any(_containsScenarioMetaText)) {
      return false;
    }
    if (scenario.aiRole.trim().toLowerCase() ==
        scenario.userRole.trim().toLowerCase()) {
      return false;
    }
    final hasZh =
        _containsCjk(scenario.titleZh) ||
        _containsCjk(scenario.settingZh) ||
        _containsCjk(scenario.aiRoleZh) ||
        _containsCjk(scenario.userRoleZh) ||
        scenario.stagesZh.any(_containsCjk);
    if (!hasZh) {
      return false;
    }
    return true;
  }

  bool _containsScenarioMetaText(String value) {
    final v = value.toLowerCase();
    final raw = value.trim();
    if (v.trim().isEmpty) return true;
    return v.contains('output exactly') ||
        v.contains('return only') ||
        v.contains('target words') ||
        v.contains('use these') ||
        v.contains('prompt') ||
        v.contains('json') ||
        v.contains('current step') ||
        v.contains('student message now') ||
        v.contains('focus words') ||
        v.contains('reply hint') ||
        v.contains('ai vocabulary') ||
        v.contains('ai-driven') ||
        v.contains('scenario:') ||
        raw.contains('單字導向情境') ||
        raw.contains('請根據') ||
        raw.contains('圍繞這些單字') ||
        raw.contains('你正在協助');
  }

  bool _containsCjk(String value) {
    return RegExp(r'[\u4e00-\u9fff]').hasMatch(value);
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
    if (current == null || _chatSession == null) return;
    if (current.isSessionEnded) return;

    if (current.isQuotaExhausted ||
        current.useLocalCoachOnly ||
        _isOverTokenBudget()) {
      if (addToUi) {
        _addUserMessage(text);
      }
      _appendLocalCoachTurn(userText: text);
      return;
    }
    if (_refreshCooldownState() || !_canUseRemoteChat(current)) {
      if (addToUi) {
        _addUserMessage(text);
      }
      _appendLocalCoachTurn(userText: text);
      return;
    }

    final wordCount = VocabularyTracker.targetTermsPerTurn(arg.difficulty);
    final turnStartCursor = _vocab.focusCursor;
    _vocab.advanceFocusCursor(wordCount);
    final payload = _buildPromptWithCoverageHint(
      text,
      addToUi: addToUi,
      isFirstTurn: isFirstTurn,
      fixedPriorityTerms: _vocab.nextPriorityTerms(
        count: wordCount,
        startOffset: turnStartCursor,
      ),
    );

    // Track used terms
    Set<String> usedNow = {};
    if (addToUi) {
      usedNow = _vocab.extractUsedTerms(text);
      if (usedNow.isNotEmpty) {
        _vocab.practicedTerms.addAll(usedNow);
      }
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
      final response = await _chatSession!.sendMessage(Content.text(payload));
      final responseText = response.text ?? '';
      _estimatedTotalTokens +=
          _estimateTokensFromChars(payload.length) +
          _estimateTokensFromChars(responseText.length);
      await _applyAiResponse(
        responseText: responseText,
        text: text,
        addToUi: addToUi,
        usedNow: usedNow,
        wordCount: wordCount,
        turnStartCursor: turnStartCursor,
      );
      _consecutiveApiFailures = 0;
      _chatMinGapMs = 1500;
    } on GenerativeAIException catch (e) {
      final retried = await _retryWithNextChatModel(
        payload: payload,
        text: text,
        addToUi: addToUi,
        usedNow: usedNow,
        wordCount: wordCount,
        turnStartCursor: turnStartCursor,
      );
      if (retried) return;
      _handleApiError(e.toString(), text);
    } catch (e) {
      _handleGenericError(text);
    }
  }

  Future<void> _applyAiResponse({
    required String responseText,
    required String text,
    required bool addToUi,
    required Set<String> usedNow,
    required int wordCount,
    required int turnStartCursor,
  }) async {
    final parsed = _parseAiTurnContent(responseText);
    var aiText = parsed.question;
    final requiredFocusTerms = _vocab.nextPriorityTerms(
      count: wordCount,
      startOffset: turnStartCursor,
    );
    if (!_containsAnyFocusTerm(aiText, requiredFocusTerms)) {
      aiText = _buildFocusAlignedFallbackQuestion(requiredFocusTerms);
    }
    if (!_isScenarioAlignedQuestion(aiText)) {
      aiText = _buildScenarioAlignedFallbackQuestion(requiredFocusTerms);
    }
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
          replyHint: parsed.replyHint,
          termsUsed: usedNow,
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
        latestReplyHint: parsed.replyHint,
        currentTurn: newTurn,
        chatApiCalls: s.chatApiCalls + 1,
        isSessionEnded: isEnded,
      ),
    );

    if (addToUi) {
      _evaluateTurnAsync(newTurn - 1, aiText, text);
    }
    if (isEnded) {
      await _writeReviewLogs();
    }
  }

  Future<bool> _retryWithNextChatModel({
    required String payload,
    required String text,
    required bool addToUi,
    required Set<String> usedNow,
    required int wordCount,
    required int turnStartCursor,
  }) async {
    while (_switchToNextChatModel()) {
      try {
        await _respectChatRateLimit();
        final response = await _chatSession!.sendMessage(Content.text(payload));
        final responseText = response.text ?? '';
        _estimatedTotalTokens +=
            _estimateTokensFromChars(payload.length) +
            _estimateTokensFromChars(responseText.length);
        await _applyAiResponse(
          responseText: responseText,
          text: text,
          addToUi: addToUi,
          usedNow: usedNow,
          wordCount: wordCount,
          turnStartCursor: turnStartCursor,
        );
        _consecutiveApiFailures = 0;
        _chatMinGapMs = 1500;
        return true;
      } on GenerativeAIException catch (e) {
        // Stop retrying on 429 — further calls will worsen rate limiting
        if (_classifyApiIssue(e.toString()) == _ApiIssueType.rateLimit) {
          return false;
        }
        continue;
      } catch (_) {
        continue;
      }
    }
    return false;
  }

  void _handleApiError(String rawError, String userText) {
    _updateState((s) => s.copyWith(isAiTyping: false));
    final issueType = _classifyApiIssue(rawError);
    if (issueType == _ApiIssueType.hardQuota) {
      _updateState(
        (s) => s.copyWith(isQuotaExhausted: true, useLocalCoachOnly: true),
      );
      _appendLocalCoachTurn(userText: userText);
    } else if (issueType == _ApiIssueType.rateLimit) {
      _startRateCooldown();
      // After 3+ rate limit hits, stay on local coach for the rest of this session
      final permanent = _rateLimitHitCount >= 3;
      _updateState(
        (s) => s.copyWith(
          useLocalCoachOnly: true,
          isQuotaExhausted: permanent ? true : s.isQuotaExhausted,
        ),
      );
      _appendLocalCoachTurn(userText: userText);
    } else {
      _consecutiveApiFailures++;
      if (_consecutiveApiFailures >= 2) {
        _updateState((s) => s.copyWith(useLocalCoachOnly: true));
        _appendLocalCoachTurn(userText: userText);
      }
    }
  }

  void _handleGenericError(String userText) {
    _updateState((s) => s.copyWith(isAiTyping: false));
    _consecutiveApiFailures++;
    if (_consecutiveApiFailures >= 2) {
      _updateState((s) => s.copyWith(useLocalCoachOnly: true));
      _appendLocalCoachTurn(userText: userText);
    }
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
  void _evaluateTurnAsync(
    int turnIndex,
    String aiQuestion,
    String userResponse,
  ) {
    final apiKey = ref.read(geminiKeyProvider);
    final current = state.valueOrNull;
    if (current == null || apiKey.isEmpty) {
      _evaluateTurnOffline(turnIndex, userResponse);
      return;
    }

    ConversationScorer.evaluateTurn(
          apiKey: apiKey,
          aiQuestion: aiQuestion,
          userResponse: userResponse,
          scenarioTitle: current.scenarioTitle,
          difficulty: arg.difficulty,
          targetTerms: _vocab.targetTerms,
        )
        .then((feedback) {
          final actualFeedback =
              feedback ??
              ConversationScorer.evaluateOffline(
                userResponse: userResponse,
                targetTerms: _vocab.targetTerms,
              );
          _updateTurnFeedback(turnIndex, actualFeedback);
        })
        .catchError((_) {
          _evaluateTurnOffline(turnIndex, userResponse);
        });
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

  String _currentChatModel() {
    final models = GeminiService.chatModels;
    if (models.isEmpty) {
      return 'gemini-2.0-flash-lite';
    }
    if (_chatModelIndex < 0 || _chatModelIndex >= models.length) {
      _chatModelIndex = 0;
    }
    return models[_chatModelIndex];
  }

  bool _switchToNextChatModel() {
    final models = GeminiService.chatModels;
    if (_chatModelIndex + 1 >= models.length) return false;
    final current = state.valueOrNull;
    if (current == null) return false;
    final apiKey = ref.read(geminiKeyProvider);
    if (apiKey.isEmpty) return false;

    _chatModelIndex += 1;
    _chatSession = GeminiService.startConversation(
      apiKey: apiKey,
      terms: _vocab.targetTerms,
      difficulty: arg.difficulty,
      totalTurns: arg.turns,
      scenarioTitle: current.scenarioTitle,
      scenarioSetting: current.scenarioSetting,
      aiRole: current.aiRole,
      userRole: current.userRole,
      chatModel: _currentChatModel(),
    );
    return true;
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

  _ApiIssueType _classifyApiIssue(String raw) {
    final msg = raw.toLowerCase();
    final rateLimited =
        msg.contains('429') ||
        msg.contains('rate limit') ||
        msg.contains('rate_limit') ||
        msg.contains('too many requests') ||
        msg.contains('per minute') ||
        msg.contains('requests per minute');
    if (rateLimited) return _ApiIssueType.rateLimit;

    final hardQuota =
        msg.contains('resource_exhausted') ||
        msg.contains('resource has been exhausted') ||
        (msg.contains('quota') && msg.contains('per day'));
    if (hardQuota) return _ApiIssueType.hardQuota;

    final isAuth =
        msg.contains('api key not valid') ||
        msg.contains('permission denied') ||
        msg.contains('unauthenticated') ||
        msg.contains('401') ||
        msg.contains('403');
    if (isAuth) return _ApiIssueType.auth;

    if (msg.contains('api')) return _ApiIssueType.other;
    return _ApiIssueType.none;
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

  String _buildPromptWithCoverageHint(
    String userText, {
    required bool addToUi,
    required bool isFirstTurn,
    List<String>? fixedPriorityTerms,
  }) {
    final wordCount = VocabularyTracker.targetTermsPerTurn(arg.difficulty);
    final priorityTerms =
        fixedPriorityTerms ?? _vocab.nextPriorityTerms(count: wordCount);
    final fallbackCount = wordCount;
    final focusTerms = priorityTerms.isEmpty
        ? _vocab.targetTerms.take(fallbackCount).toList()
        : priorityTerms;
    final focusText = focusTerms.isEmpty ? '' : focusTerms.join(', ');
    final meaningHints = focusTerms
        .map((t) {
          final def = (_vocab.termDefinitions[t] ?? '').trim();
          if (def.isEmpty) return '';
          final shortDef = def.length > 14 ? '${def.substring(0, 14)}...' : def;
          return '$t:$shortDef';
        })
        .where((line) => line.isNotEmpty)
        .join(';');
    final sanitizedInput = addToUi ? _sanitizeUserInput(userText) : '';

    final current = state.valueOrNull;
    final stage = (current?.stages.isEmpty ?? true)
        ? 'Continue the conversation naturally.'
        : current!.stages[current.currentTurn % current.stages.length];

    final studentLine = isFirstTurn
        ? '(first turn)'
        : (sanitizedInput.isEmpty ? '(empty)' : sanitizedInput);

    final adaptHint = _adaptDifficultyHint();

    if (!isFirstTurn) {
      return '''
Step: $stage
Student: $studentLine
Focus words: $focusText
Word notes: ${meaningHints.isEmpty ? 'N/A' : meaningHints}$adaptHint
Output exactly two lines:
Question: ...
Reply hint: Start with "..."
Question MUST include at least one Focus word exactly as written.
''';
    }

    return '''
Current step: $stage
Student message now: $studentLine
Use these target words: $focusText
Word notes: ${meaningHints.isEmpty ? 'N/A' : meaningHints}
Output exactly two lines:
Question: ...
Reply hint: Start with "..."
Question MUST include at least one target word exactly as written.
''';
  }

  _AiTurnContent _parseAiTurnContent(String text) {
    var cleaned = text.trim();
    cleaned = cleaned.replaceFirst(
      RegExp(r'^(hi|hello|hey)\b[^\n]*\n?', caseSensitive: false),
      '',
    );
    cleaned = cleaned.replaceAll(RegExp(r'^\s*[-*]\s*', multiLine: true), '');

    String question = '';
    String hint = '';
    for (final line in cleaned.split('\n')) {
      final trimmed = line.trim();
      final lower = trimmed.toLowerCase();
      if (lower.startsWith('question:')) {
        question = trimmed.substring('question:'.length).trim();
      } else if (lower.startsWith('reply hint:')) {
        hint = trimmed.substring('reply hint:'.length).trim();
      }
    }

    if (question.isEmpty) {
      final lines = cleaned
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .where((e) {
            final lower = e.toLowerCase();
            return !lower.startsWith('scenario:') &&
                !lower.startsWith('setting:') &&
                !lower.startsWith('ai role:') &&
                !lower.startsWith('your role:') &&
                !lower.startsWith('user role:') &&
                !lower.startsWith('objective:') &&
                !lower.startsWith('next objective:') &&
                !lower.startsWith('current step:') &&
                !lower.startsWith('step:') &&
                !lower.startsWith('focus words:') &&
                !lower.startsWith('word notes:') &&
                !lower.startsWith('output exactly') &&
                !lower.startsWith('reply hint:');
          })
          .toList();
      question = lines.isEmpty
          ? 'What do you need in this situation?'
          : lines.first;
    }
    question = question
        .replaceFirst(RegExp(r'^(question:)\s*', caseSensitive: false), '')
        .trim();
    question = _normalizeQuestion(question);
    if (_looksUnnaturalQuestion(question)) {
      question = _buildFallbackQuestion();
    }

    if (hint.isEmpty) {
      final starterTerms = _vocab.nextPriorityTerms(count: 1);
      final starter = starterTerms.isEmpty
          ? 'I would like'
          : starterTerms.first;
      hint = 'Start with "$starter ..."';
    }
    hint = hint
        .replaceFirst(RegExp(r'^(reply hint:)\s*', caseSensitive: false), '')
        .trim();

    return _AiTurnContent(question: question, replyHint: hint);
  }

  String _normalizeQuestion(String question) {
    var value = question.trim();
    if (value.isEmpty) return value;
    final aiRole = (state.valueOrNull?.aiRole ?? '').toLowerCase();
    final isServiceRole =
        aiRole.contains('staff') ||
        aiRole.contains('barista') ||
        aiRole.contains('pharmacist') ||
        aiRole.contains('librarian') ||
        aiRole.contains('receptionist') ||
        aiRole.contains('host') ||
        aiRole.contains('telecom') ||
        aiRole.contains('landlord') ||
        aiRole.contains('academic');
    if (isServiceRole &&
        RegExp(r'^where can i find\b', caseSensitive: false).hasMatch(value)) {
      value = 'What are you looking for today';
    }
    value = value.replaceAll(
      RegExp(r'^where do you think i can find\b', caseSensitive: false),
      'Where can I find',
    );
    value = value.replaceAll(
      RegExp(r'\bto the attach\b', caseSensitive: false),
      'to attach',
    );
    value = value.replaceAll(RegExp(r'\s{2,}'), ' ');
    if (!value.endsWith('?')) {
      value = '$value?';
    }
    return value;
  }

  bool _looksUnnaturalQuestion(String question) {
    final q = question.toLowerCase();
    if (q.isEmpty) return true;
    if (q.contains('to the attach')) return true;
    if (q.contains('where do you think i can find')) return true;
    if (q.contains('lack confidence') ||
        q.contains('low confidence') ||
        q.contains('self-esteem') ||
        q.contains('confident person') ||
        q.contains('personality test')) {
      return true;
    }
    if (q.contains('bulletproof') &&
        (q.contains('supermarket') ||
            (state.valueOrNull?.scenarioTitle.toLowerCase().contains(
                  'supermarket',
                ) ??
                false))) {
      return true;
    }
    if (!q.contains('?')) return true;
    return false;
  }

  String _buildFallbackQuestion() {
    final current = state.valueOrNull;
    final focus = _vocab.nextPriorityTerms(count: 1);
    final lead = focus.isEmpty ? 'this item' : focus.first;
    final scenario = (current?.scenarioTitle ?? '').toLowerCase();
    if (scenario.contains('supermarket')) {
      return 'What are you looking for today, especially about $lead?';
    }
    if (scenario.contains('cafe')) {
      return 'Could you tell me your order details for $lead?';
    }
    if (scenario.contains('pharmacy')) {
      return 'What do you need help with regarding $lead today?';
    }
    return 'What do you need today about $lead?';
  }

  bool _containsAnyFocusTerm(String question, List<String> focusTerms) {
    if (focusTerms.isEmpty) return true;
    final q = question.toLowerCase();
    for (final term in focusTerms) {
      final t = term.trim().toLowerCase();
      if (t.isEmpty) continue;
      if (q.contains(t)) return true;
    }
    return false;
  }

  String _buildFocusAlignedFallbackQuestion(List<String> focusTerms) {
    final lead = focusTerms.isEmpty ? 'this item' : focusTerms.first;
    final aiRole = (state.valueOrNull?.aiRole ?? '').toLowerCase();
    if (aiRole.contains('staff') ||
        aiRole.contains('barista') ||
        aiRole.contains('pharmacist')) {
      return 'What do you need today related to $lead?';
    }
    return 'Could you explain what you need about $lead?';
  }

  bool _isScenarioAlignedQuestion(String question) {
    final q = question.toLowerCase();

    // Hard block obvious off-topic mental/personality probes.
    if (q.contains('confidence') ||
        q.contains('self-esteem') ||
        q.contains('personality') ||
        q.contains('personality test') ||
        q.contains('emotion') ||
        q.contains('mindset') ||
        q.contains('belief system')) {
      return false;
    }

    // Accept anything else — the scenario prompt already constrains the AI.
    return true;
  }

  String _buildScenarioAlignedFallbackQuestion(List<String> focusTerms) {
    final lead = focusTerms.isEmpty ? 'this item' : focusTerms.first;
    final current = state.valueOrNull;
    final aiRole = (current?.aiRole ?? '').trim();
    final step = (current?.stages.isEmpty ?? true)
        ? ''
        : current!.stages[current.currentTurn % current.stages.length];
    final stepHint = step.isNotEmpty ? ' Right now, let\'s $step.' : '';
    if (aiRole.isNotEmpty) {
      return 'As your $aiRole, what can I help you with regarding $lead?$stepHint';
    }
    return 'What do you need today about $lead?$stepHint';
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

enum _ApiIssueType { none, hardQuota, rateLimit, auth, other }

class _AiTurnContent {
  final String question;
  final String replyHint;
  const _AiTurnContent({required this.question, required this.replyHint});
}
