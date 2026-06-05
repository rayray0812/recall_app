import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/core/widgets/app_back_button.dart';
import 'package:recall_app/features/study/models/conversation_transcript.dart';
import 'package:recall_app/features/study/models/conversation_turn_record.dart';
import 'package:recall_app/features/study/services/voice_playback_service.dart';
import 'package:recall_app/features/study/widgets/turn_feedback_chip.dart';
import 'package:recall_app/features/study/widgets/typing_indicator.dart';
import 'package:recall_app/features/study/widgets/quick_action_bar.dart';
import 'package:recall_app/features/study/widgets/voice_wave_indicator.dart';
import 'package:recall_app/providers/ai_runtime_provider.dart';
import 'package:recall_app/providers/conversation_session_provider.dart';
import 'package:recall_app/providers/gemini_key_provider.dart';
import 'package:recall_app/providers/study_set_provider.dart';
import 'package:recall_app/providers/tts_engine_provider.dart';
import 'package:recall_app/services/ai/ai_quota_messages.dart';
import 'package:recall_app/services/ai_tts_service.dart';
import 'package:speech_to_text/speech_to_text.dart';

class ConversationPracticeScreen extends ConsumerStatefulWidget {
  final String setId;
  final int turns;
  final String difficulty;
  final String? scenarioId;

  const ConversationPracticeScreen({
    super.key,
    required this.setId,
    required this.turns,
    required this.difficulty,
    this.scenarioId,
  });

  @override
  ConsumerState<ConversationPracticeScreen> createState() =>
      _ConversationPracticeScreenState();

  static ConversationTranscript? selectSummaryTranscript({
    required List<ConversationTranscript> transcripts,
    required String setId,
    required String difficulty,
    required String scenarioTitle,
    required int totalTurns,
  }) {
    for (final transcript in transcripts) {
      if (transcript.setId == setId &&
          transcript.difficulty.toLowerCase() == difficulty.toLowerCase() &&
          transcript.scenarioTitle == scenarioTitle &&
          transcript.totalTurns == totalTurns) {
        return transcript;
      }
    }
    for (final transcript in transcripts) {
      if (transcript.setId == setId) {
        return transcript;
      }
    }
    return transcripts.isEmpty ? null : transcripts.first;
  }
}

class _ConversationPracticeScreenState
    extends ConsumerState<ConversationPracticeScreen> {
  late final VoicePlaybackService _voice;
  late SpeechToText _stt;
  ProviderSubscription<String>? _geminiKeySubscription;
  bool _sttAvailable = false;
  bool _isListening = false;
  bool _isDisposed = false;
  bool _sessionStarted = false;
  bool _isStartingSession = false;
  bool _isSessionBootstrapping = true;
  bool _didPlayFirstAiLine = false;
  bool _showScenarioChinese = false;
  bool _showReplyHint = false;
  double _soundLevel = 0.0;
  late bool _isMuted;

  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  ConversationSessionParams get _params => ConversationSessionParams(
    setId: widget.setId,
    turns: widget.turns,
    difficulty: widget.difficulty,
    scenarioId: widget.scenarioId,
  );

  ConversationSessionNotifier get _notifier =>
      ref.read(conversationSessionProvider(_params).notifier);

  @override
  void initState() {
    super.initState();
    _isMuted = ref.read(localStorageServiceProvider).isConversationMuted;
    _voice = VoicePlaybackService();
    _voice.init();
    _initStt();
    _geminiKeySubscription = ref.listenManual<String>(geminiKeyProvider, (
      previous,
      next,
    ) {
      if (!mounted || _isDisposed) return;
      if (next.trim().isEmpty) return;
      final session = ref
          .read(conversationSessionProvider(_params))
          .valueOrNull;
      if (_isStartingSession || (session?.messages.isNotEmpty ?? false)) return;
      _startSession();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _sessionStarted) return;
      _sessionStarted = true;
      _startSession();
    });
  }

  Future<void> _initStt() async {
    _stt = SpeechToText();
    try {
      _sttAvailable = await _stt.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      if (kDebugMode) debugPrint("STT init error: $e");
    }
  }

  Future<String?> _resolveSttLocale() async {
    final locales = await _stt.locales();
    if (locales.isEmpty) return null;
    for (final locale in locales) {
      final id = locale.localeId.toLowerCase().replaceAll('_', '-');
      if (id == 'en-us' || id.startsWith('en-us')) return locale.localeId;
    }
    for (final locale in locales) {
      final id = locale.localeId.toLowerCase().replaceAll('_', '-');
      if (id.startsWith('en')) return locale.localeId;
    }
    return locales.first.localeId;
  }

  Future<void> _startSession() async {
    if (_isStartingSession) return;
    _isStartingSession = true;
    try {
      final l10n = AppLocalizations.of(context);
      final apiKey = await _waitForGeminiKey();
      if (!mounted || _isDisposed) return;
      if (apiKey.isEmpty) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(l10n.geminiApiKeyNotSet)));
        return;
      }

      if (!mounted || _isDisposed) return;
      final notifier = ref.read(conversationSessionProvider(_params).notifier);
      await notifier.startSession();
      if (!mounted || _isDisposed) return;
      // Pre-generate first AI audio
      final sessionState = ref
          .read(conversationSessionProvider(_params))
          .valueOrNull;
      if (sessionState != null && sessionState.messages.isNotEmpty) {
        final lastMsg = sessionState.messages.last;
        if (lastMsg.isAi && lastMsg.text.isNotEmpty) {
          final apiKey = ref.read(geminiKeyProvider);
          if (apiKey.isNotEmpty && !(sessionState.useLocalCoachOnly)) {
            try {
              await AiTtsService.prepareFirstLineAudio(
                apiKey: apiKey,
                text: lastMsg.text,
              ).timeout(
                const Duration(milliseconds: 1200),
                onTimeout: () async => false,
              );
            } catch (e) {
              if (kDebugMode) {
                debugPrint('prepareFirstLineAudio failed: $e');
              }
            }
          }
          _speakLatestAiQuestionOnce();
        }
      }
    } finally {
      _isStartingSession = false;
      if (mounted && !_isDisposed && _isSessionBootstrapping) {
        setState(() => _isSessionBootstrapping = false);
      }
    }
  }

  Future<String> _waitForGeminiKey() async {
    final startedAt = DateTime.now();
    var key = ref.read(geminiKeyProvider).trim();
    while (key.isEmpty &&
        DateTime.now().difference(startedAt).inMilliseconds < 1500) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted || _isDisposed) return '';
      key = ref.read(geminiKeyProvider).trim();
    }
    return key;
  }

  void _speakLatestAiQuestionOnce() {
    if (!mounted || _didPlayFirstAiLine) return;
    if (_isDisposed) return;
    final sessionState = ref
        .read(conversationSessionProvider(_params))
        .valueOrNull;
    if (sessionState == null || sessionState.messages.isEmpty) return;
    final last = sessionState.messages.last;
    if (!last.isAi || last.text.trim().isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _didPlayFirstAiLine = true;
      if (!_isMuted) _playAiMessage(last.text);
    });
  }

  void _playAiMessage(String text) {
    if (!mounted || _isDisposed) return;
    final engine = ref.read(ttsEngineProvider);
    // Sync backend setting
    if (engine == TtsEngine.geminiTts) {
      AiTtsService.setBackend(TtsBackend.geminiTts);
    } else {
      AiTtsService.setBackend(TtsBackend.cloudTts);
    }
    final sessionState = ref
        .read(conversationSessionProvider(_params))
        .valueOrNull;
    _voice.playAiMessage(
      text,
      useLocalCoachOnly: sessionState?.useLocalCoachOnly ?? false,
      useDeviceOnly: engine == TtsEngine.deviceTts,
      apiKey: ref.read(geminiKeyProvider),
      onStateChanged: (state, diag) {
        if (_isDisposed || !mounted) return;
        try {
          _notifier.updateVoiceState(state.name, diag);
          if (state == VoiceState.completed || state == VoiceState.error) {
            _showTtsIndicator(diag);
          }
        } catch (_) {}
      },
    );
  }

  void _showTtsIndicator(String message) {
    if (!mounted || _isDisposed) return;
    ScaffoldMessenger.maybeOf(context)
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
  }

  void _handleUserSubmit() {
    if (!mounted || _isDisposed) return;
    final sessionState = ref
        .read(conversationSessionProvider(_params))
        .valueOrNull;
    if (sessionState == null ||
        sessionState.isAiTyping ||
        sessionState.isSessionEnded) {
      return;
    }
    final text = _textController.text.trim();
    if (text.isEmpty) {
      return;
    }
    _textController.clear();
    _notifier.sendMessage(text).then((_) {
      if (!mounted || _isDisposed) return;
      // After AI responds, speak the new AI message (unless muted)
      if (_isMuted) return;
      final updated = ref
          .read(conversationSessionProvider(_params))
          .valueOrNull;
      if (updated != null && updated.messages.isNotEmpty) {
        final last = updated.messages.last;
        if (last.isAi && last.text.isNotEmpty) {
          _playAiMessage(last.text);
        }
      }
    }).catchError((_) {
      // Keep UI stable when async send completes after disposal.
    });
  }

  Future<void> _toggleListening() async {
    if (!_sttAvailable || _isDisposed) return;
    if (_isListening) {
      await _stt.stop();
      if (!mounted || _isDisposed) return;
      setState(() => _isListening = false);
    } else {
      final localeId = await _resolveSttLocale();
      if (!mounted || _isDisposed) return;
      setState(() => _isListening = true);
      await _stt.listen(
        localeId: localeId,
        onSoundLevelChange: (level) {
          if (!mounted || _isDisposed) return;
          setState(() => _soundLevel = level);
        },
        onResult: (result) {
          if (!mounted || _isDisposed) return;
          _textController.value = TextEditingValue(
            text: result.recognizedWords,
            selection: TextSelection.collapsed(
              offset: result.recognizedWords.length,
            ),
          );
          if (result.finalResult) {
            if (!mounted || _isDisposed) return;
            setState(() {
              _isListening = false;
              _soundLevel = 0.0;
            });
          }
        },
      );
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isDisposed) return;
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _navigateToSummary(BuildContext context) {
    if (!mounted || _isDisposed) return;
    final localStorage = ref.read(localStorageServiceProvider);
    final transcripts = localStorage.getAllConversationTranscripts();
    final session = ref.read(conversationSessionProvider(_params)).valueOrNull;
    if (transcripts.isNotEmpty && session != null) {
      final transcript = ConversationPracticeScreen.selectSummaryTranscript(
        transcripts: transcripts,
        setId: widget.setId,
        difficulty: widget.difficulty,
        scenarioTitle: session.scenarioTitle,
        totalTurns: session.turnRecords.length,
      );
      if (transcript == null) return;
      context.push(
        '/study/${widget.setId}/conversation/practice/summary',
        extra: transcript,
      );
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    // Clear SnackBars before disposal to avoid disposed AnimationController errors
    try {
      ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
    } catch (_) {}
    _geminiKeySubscription?.close();
    _voice.dispose();
    _stt.cancel();
    _textController.dispose();
    _scrollController.dispose();
    AiTtsService.clearCache();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    final isKeyboardOpen = keyboardInset > 0;
    final asyncSession = ref.watch(conversationSessionProvider(_params));

    if (_isSessionBootstrapping) {
      return Scaffold(
        appBar: AppBar(
          leading: const AppBackButton(),
          title: Text(l10n.conversationPractice),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return asyncSession.when(
      loading: () => Scaffold(
        appBar: AppBar(
          leading: const AppBackButton(),
          title: Text(l10n.conversationPractice),
        ),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(
          leading: const AppBackButton(),
          title: Text(l10n.conversationPractice),
        ),
        body: Center(child: Text('Error: $e')),
      ),
      data: (session) {
        // Auto-scroll when messages change
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToBottom();
        });

        return Scaffold(
          appBar: AppBar(
            leading: const AppBackButton(),
            title: Text(
              '${l10n.conversationPractice} (${session.currentTurn}/${widget.turns})',
            ),
            actions: [
              IconButton(
                icon: Icon(_isMuted
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded),
                tooltip: _isMuted ? l10n.unmuteAutoPlay : l10n.muteAutoPlay,
                onPressed: () {
                  setState(() => _isMuted = !_isMuted);
                  ref.read(localStorageServiceProvider).setConversationMuted(_isMuted);
                },
              ),
            ],
          ),
          body: Column(
            children: [
              if (session.isQuotaExhausted)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: _buildQuotaBanner(theme),
                ),
              if (!isKeyboardOpen) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: _buildScenarioPanel(theme, l10n, session),
                ),
                if (kDebugMode)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: _buildApiGuardPanel(theme, l10n, session),
                  ),
                if (session.targetTerms.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: _buildCoveragePanel(theme, l10n, session),
                  ),
              ],
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount:
                      session.messages.length + (session.isAiTyping ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == session.messages.length) {
                      return const TypingIndicator();
                    }
                    final msg = session.messages[index];
                    return _buildMessageBubble(msg, theme, session);
                  },
                ),
              ),
              if (!session.isSessionEnded)
                _buildInputArea(theme, l10n, isKeyboardOpen, session),
              if (session.isSessionEnded)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text(
                        l10n.practiceComplete,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () => _navigateToSummary(context),
                        icon: const Icon(Icons.assessment_rounded),
                        label: Text(l10n.conversationSummary),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInputArea(
    ThemeData theme,
    AppLocalizations l10n,
    bool isKeyboardOpen,
    ConversationSessionState session,
  ) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        isKeyboardOpen ? 8 : 16,
        16,
        isKeyboardOpen ? 8 : 16,
      ),
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: isKeyboardOpen ? 120 : 340),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isKeyboardOpen)
                  QuickActionBar(
                    enabled: !session.isAiTyping && !session.isSessionEnded,
                    onAction: (msg) {
                      _textController.text = msg;
                      _handleUserSubmit();
                    },
                  ),
                if (!isKeyboardOpen &&
                    session.latestReplyHint.trim().isNotEmpty)
                  _buildReplyHintPanel(theme, l10n, session),
                if (!isKeyboardOpen)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed:
                          session.isAiTyping ||
                              session.isSessionEnded ||
                              session.isGeneratingSuggestions
                          ? null
                          : () => _notifier.generateSuggestions(),
                      icon: session.isGeneratingSuggestions
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_awesome_rounded, size: 18),
                      label: Text(l10n.helpMeReply),
                    ),
                  ),
                if (!isKeyboardOpen && session.suggestedReplies.isNotEmpty)
                  _buildSuggestedRepliesPanel(theme, l10n, session),
                _buildTextInputRow(theme, l10n, session),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextInputRow(
    ThemeData theme,
    AppLocalizations l10n,
    ConversationSessionState session,
  ) {
    return Row(
      children: [
        if (_sttAvailable) ...[
          IconButton.filledTonal(
            onPressed: _toggleListening,
            icon: Icon(_isListening ? Icons.mic : Icons.mic_none),
            color: _isListening ? theme.colorScheme.error : null,
          ),
          if (_isListening)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: VoiceWaveIndicator(soundLevel: _soundLevel),
            ),
        ],
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _textController,
            decoration: InputDecoration(
              hintText: l10n.typeYourAnswer,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
            onSubmitted: (_) => _handleUserSubmit(),
          ),
        ),
        const SizedBox(width: 8),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _textController,
          builder: (context, value, _) {
            final canSend =
                !session.isAiTyping &&
                !session.isSessionEnded &&
                value.text.trim().isNotEmpty;
            return IconButton.filled(
              onPressed: canSend ? _handleUserSubmit : null,
              icon: const Icon(Icons.send_rounded),
            );
          },
        ),
      ],
    );
  }

  /// Find the turn record matching a user message by text.
  ConversationTurnRecord? _findTurnRecord(
    String userText,
    ConversationSessionState session,
  ) {
    for (final record in session.turnRecords) {
      if (record.userResponse == userText) return record;
    }
    return null;
  }

  Widget _buildMessageBubble(
    ChatMessageData msg,
    ThemeData theme,
    ConversationSessionState session,
  ) {
    final l10n = AppLocalizations.of(context);
    final isAi = msg.isAi;
    final turnRecord = isAi ? null : _findTurnRecord(msg.text, session);
    return Align(
      alignment: isAi ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        decoration: BoxDecoration(
          color: isAi
              ? theme.colorScheme.secondaryContainer
              : theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isAi ? session.aiRole : l10n.you,
              style: theme.textTheme.labelSmall?.copyWith(
                color: isAi
                    ? theme.colorScheme.onSecondaryContainer.withValues(
                        alpha: 0.7,
                      )
                    : theme.colorScheme.onPrimaryContainer.withValues(
                        alpha: 0.7,
                      ),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              msg.text,
              style: TextStyle(
                color: isAi
                    ? theme.colorScheme.onSecondaryContainer
                    : theme.colorScheme.onPrimaryContainer,
              ),
            ),
            if (isAi)
              GestureDetector(
                onTap: () => _playAiMessage(msg.text),
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Icon(
                    Icons.volume_up_rounded,
                    size: 16,
                    color: theme.colorScheme.onSecondaryContainer.withValues(
                      alpha: 0.5,
                    ),
                  ),
                ),
              ),
            if (!isAi && turnRecord != null)
              TurnFeedbackChip(
                feedback: turnRecord.feedback,
                isEvaluating: turnRecord.isEvaluating,
              ),
          ],
        ),
      ),
    );
  }

  /// Banner shown when the daily cloud-AI conversation quota is spent. The chat
  /// keeps working via the offline local coach; this just explains why replies
  /// changed and nudges an upgrade (§2.6).
  Widget _buildQuotaBanner(ThemeData theme) {
    final entitlement = ref.watch(aiEntitlementProvider);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.bolt_outlined,
            size: 18,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              aiQuotaUpgradeMessage(entitlement),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScenarioPanel(
    ThemeData theme,
    AppLocalizations l10n,
    ConversationSessionState session,
  ) {
    final hasStages = session.stages.isNotEmpty;
    final stageIndex = hasStages
        ? (session.currentTurn % session.stages.length)
        : 0;
    final currentObjective = hasStages
        ? session.stages[stageIndex]
        : session.currentStage;
    final currentObjectiveZh =
        session.stagesZh.isNotEmpty && stageIndex < session.stagesZh.length
        ? session.stagesZh[stageIndex]
        : session.currentStageZh;
    final nextIndex = hasStages
        ? ((stageIndex + 1) % session.stages.length)
        : 0;
    final nextObjective = hasStages ? session.stages[nextIndex] : '';
    final nextObjectiveZh =
        session.stagesZh.isNotEmpty && nextIndex < session.stagesZh.length
        ? session.stagesZh[nextIndex]
        : '';
    final showTitleZh = _hasDistinctChinese(
      session.scenarioTitleZh,
      session.scenarioTitle,
    );
    final showAiRoleZh = _hasDistinctChinese(session.aiRoleZh, session.aiRole);
    final showUserRoleZh = _hasDistinctChinese(
      session.userRoleZh,
      session.userRole,
    );
    final showSettingZh = _hasDistinctChinese(
      session.scenarioSettingZh,
      session.scenarioSetting,
    );
    final showCurrentObjectiveZh = _hasDistinctChinese(
      currentObjectiveZh,
      currentObjective,
    );
    final showNextObjectiveZh = _hasDistinctChinese(
      nextObjectiveZh,
      nextObjective,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${l10n.scenarioPrefix}${session.scenarioTitle}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _showScenarioChinese = !_showScenarioChinese;
                }),
                child: Text(_showScenarioChinese ? l10n.hideChinese : l10n.showChinese),
              ),
            ],
          ),
          if (_showScenarioChinese && showTitleZh)
            Text(
              '${l10n.scenarioZhPrefix}${session.scenarioTitleZh}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 2),
          Text(
            '${l10n.aiRoleLabelPrefix}${session.aiRole} | ${l10n.yourRoleLabelPrefix}${session.userRole}',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (_showScenarioChinese && (showAiRoleZh || showUserRoleZh)) ...[
            if (showAiRoleZh)
              Text(
                '${l10n.aiRoleLabelPrefix}${session.aiRoleZh}',
                style: theme.textTheme.bodySmall,
              ),
            if (showUserRoleZh)
              Text(
                '${l10n.yourRoleLabelPrefix}${session.userRoleZh}',
                style: theme.textTheme.bodySmall,
              ),
          ],
          const SizedBox(height: 4),
          Text(
            session.scenarioSetting,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (_showScenarioChinese && showSettingZh)
            Text(
              session.scenarioSettingZh,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          if (session.targetTerms.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '${l10n.focusTermsLabel}${session.targetTerms.join(', ')}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            '${l10n.objectiveNowLabel}$currentObjective',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (_showScenarioChinese && showCurrentObjectiveZh)
            Text(
              '${l10n.objectiveNowLabel}$currentObjectiveZh',
              style: theme.textTheme.bodySmall,
            ),
          if (nextObjective.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              '${l10n.nextObjectiveLabel}$nextObjective',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (_showScenarioChinese && showNextObjectiveZh)
              Text(
                '${l10n.nextObjectiveLabel}$nextObjectiveZh',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ],
      ),
    );
  }

  bool _hasDistinctChinese(String zh, String en) {
    final zhText = zh.trim();
    final enText = en.trim();
    if (zhText.isEmpty) return false;
    if (zhText.toLowerCase() == enText.toLowerCase()) return false;
    return RegExp(r'[\u4e00-\u9fff]').hasMatch(zhText);
  }

  Widget _buildReplyHintPanel(
    ThemeData theme,
    AppLocalizations l10n,
    ConversationSessionState session,
  ) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _showReplyHint = !_showReplyHint),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.tips_and_updates_rounded,
                    size: 18,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.replyHintTitle,
                    style: TextStyle(
                      color: theme.colorScheme.onTertiaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _showReplyHint
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ],
              ),
            ),
          ),
          if (_showReplyHint)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 8, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      session.latestReplyHint,
                      style: TextStyle(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      _textController.value = TextEditingValue(
                        text: session.latestReplyHint,
                        selection: TextSelection.collapsed(
                          offset: session.latestReplyHint.length,
                        ),
                      );
                    },
                    child: Text(l10n.useHint),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSuggestedRepliesPanel(
    ThemeData theme,
    AppLocalizations l10n,
    ConversationSessionState session,
  ) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.tryTheseReplies,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 170),
            child: SingleChildScrollView(
              child: Column(
                children: session.suggestedReplies.asMap().entries.map((entry) {
                  final index = entry.key + 1;
                  final suggestion = entry.value;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$index.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                suggestion.reply,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (suggestion.zhHint.isNotEmpty)
                                Text(
                                  suggestion.zhHint,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              if (suggestion.focusWord.isNotEmpty)
                                Text(
                                  'Focus: ${suggestion.focusWord}',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            _textController.value = TextEditingValue(
                              text: suggestion.reply,
                              selection: TextSelection.collapsed(
                                offset: suggestion.reply.length,
                              ),
                            );
                          },
                          child: Text(l10n.useHint),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCoveragePanel(
    ThemeData theme,
    AppLocalizations l10n,
    ConversationSessionState session,
  ) {
    final practiced = session.practicedTerms.length;
    final total = session.targetTerms.length;
    final progress = total == 0 ? 0.0 : practiced / total;
    final remaining = session.targetTerms
        .where((t) => !session.practicedTerms.contains(t))
        .take(4)
        .toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                l10n.targetCoverage,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '$practiced / $total',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 8,
              value: progress.clamp(0.0, 1.0),
            ),
          ),
          if (remaining.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: remaining
                  .map(
                    (w) => Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text(w),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildApiGuardPanel(
    ThemeData theme,
    AppLocalizations l10n,
    ConversationSessionState session,
  ) {
    final mode = session.useLocalCoachOnly
        ? l10n.modeLocalCoach
        : (session.isQuotaExhausted
              ? l10n.modeQuotaLimited
              : l10n.modeRemoteAi);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          _tinyBadge(theme, 'Mode: $mode'),
          _tinyBadge(theme, '${l10n.chatApiLabel}: ${session.chatApiCalls}'),
          _tinyBadge(
            theme,
            '${l10n.ideasApiLabel}: ${session.suggestionApiCalls}',
          ),
          _tinyBadge(theme, '${l10n.voiceLabel}: ${session.voiceStateName}'),
          _tinyBadge(theme, session.voiceDiagnostic),
          if (session.isInRateCooldown)
            _tinyBadge(theme, l10n.cooldownLabel(session.cooldownSecondsLeft)),
        ],
      ),
    );
  }

  Widget _tinyBadge(ThemeData theme, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(text, style: theme.textTheme.labelSmall),
    );
  }
}
