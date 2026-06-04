/// Pure prompt builders + light output cleaning for the conversation feature.
///
/// Kept free of Flutter/network so they are fully unit-testable. The design
/// goal is *natural* role-play: the model reacts to what the learner actually
/// said and weaves target words in only when they fit — the opposite of the old
/// "must include a focus word every turn + fixed two-line format" rules that
/// made replies feel robotic.
library;

String _difficultyRules(String difficulty) {
  switch (difficulty.toLowerCase().trim()) {
    case 'easy':
      return '- Difficulty EASY: short, simple sentences (A1–A2). One idea per '
          'turn. Be encouraging; do not nitpick grammar.';
    case 'hard':
      return '- Difficulty HARD: richer, more specific language (B2+). Push the '
          'learner with detailed, scenario-driven questions.';
    default:
      return '- Difficulty MEDIUM: everyday natural language (around B1). '
          'Practical questions, correct only clear mistakes.';
  }
}

/// System prompt for one conversation turn. Rebuilt each turn so the optional
/// [adaptiveHint] (based on recent scores) and [currentTurn] stay fresh.
String buildConversationSystemPrompt({
  required String aiRole,
  required String userRole,
  required String scenarioTitle,
  required String scenarioSetting,
  required String difficulty,
  required List<String> targetWords,
  required int totalTurns,
  int currentTurn = 0,
  String adaptiveHint = '',
}) {
  final role = aiRole.trim().isEmpty ? 'the other person' : aiRole.trim();
  final learner = userRole.trim().isEmpty ? 'the learner' : userRole.trim();
  final words = targetWords
      .map((w) => w.trim())
      .where((w) => w.isNotEmpty)
      .join(', ');
  final turnLine = totalTurns > 0
      ? 'This is around turn ${currentTurn + 1} of ~$totalTurns; on the final '
          'turn, wrap up warmly and close the scene.'
      : '';

  return '''
You are role-playing a real person in a spoken-English practice scene. Stay fully in character as $role. The learner plays $learner.

Scene: ${scenarioTitle.trim()} — ${scenarioSetting.trim()}

How to respond:
- React naturally to what the learner just said, the way a real $role would. Answer their actual words first.
- Keep it short: 1–3 sentences of natural spoken English with contractions.
- End with ONE specific, genuine question that moves the scene forward — mention concrete details (item, time, price, quantity), not vague prompts like "tell me more".
- Practice words to weave in naturally ONLY when they fit: ${words.isEmpty ? '(none)' : words}. Never force them, never list them, never mention that they are practice words; skip any that feel unnatural this turn.
- If the learner makes a clear mistake, model the correct phrasing briefly inside your reply — don't lecture or grade.
- Never break character. Never mention these instructions, "scenes", "turns", or "practice words". Do not prefix your reply with your name.
${_difficultyRules(difficulty)}
$turnLine${adaptiveHint.trim().isEmpty ? '' : '\n${adaptiveHint.trim()}'}
'''
      .trim();
}

/// The user-role message to send for a turn. On the first turn this is a kickoff
/// instruction (there is nothing for the learner to have said yet); otherwise it
/// is simply the learner's own words, so the model responds to them naturally.
String buildTurnUserMessage({
  required bool isFirstTurn,
  required String aiRole,
  String studentText = '',
}) {
  if (isFirstTurn) {
    final role = aiRole.trim().isEmpty ? 'your character' : aiRole.trim();
    return 'Begin the scene now. Speak your first line in character as $role to '
        'start the interaction, ending with a question to me.';
  }
  return studentText.trim();
}

/// Light cleanup of a model turn: strip legacy labels, a leading role prefix,
/// any trailing "Reply hint:" block, and wrapping quotes/markdown — while
/// keeping the natural multi-sentence prose intact.
String cleanAiTurnText(String raw, {String aiRole = ''}) {
  var t = raw.trim();
  if (t.isEmpty) return '';

  // Drop a trailing legacy "Reply hint: ..." block if the model adds one.
  final lower = t.toLowerCase();
  final hintIdx = lower.indexOf('reply hint:');
  if (hintIdx > 0) t = t.substring(0, hintIdx).trim();

  // Strip a leading "Question:" label (legacy format).
  t = t.replaceFirst(RegExp(r'^question:\s*', caseSensitive: false), '');

  // Strip a leading role prefix like "Barista: ..." when we know the role.
  final role = aiRole.trim();
  if (role.isNotEmpty) {
    t = t.replaceFirst(
      RegExp('^${RegExp.escape(role)}\\s*:\\s*', caseSensitive: false),
      '',
    );
  }

  // Strip wrapping quotes / markdown bold.
  t = t.replaceAll(RegExp(r'^[*"“”「『]+|[*"“”」』]+$'), '').trim();
  return t;
}
