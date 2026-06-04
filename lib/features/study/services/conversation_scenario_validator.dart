import 'package:recall_app/services/gemini_service.dart';

/// Pure validation for AI-generated conversation scenarios. Extracted from the
/// session provider so it is unit-testable.
///
/// IMPORTANT: this deliberately does **not** require target vocabulary to
/// appear literally in the scenario text. Vocabulary words (e.g. "ephemeral",
/// "diligent") rarely fit a scene description verbatim, and the old "must
/// mention ≥N target words" gate caused good scenarios to be rejected in favour
/// of a generic fallback — a major cause of the "scenarios feel generic / and
/// unrelated" complaint.

bool scenarioContainsCjk(String value) =>
    RegExp(r'[一-鿿]').hasMatch(value);

/// True when [value] looks like leaked prompt/meta text rather than real scene
/// content.
bool scenarioHasMetaText(String value) {
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

/// True when [title] duplicates or is contained by any recently used title.
bool isNearDuplicateScenarioTitle(String title, List<String> blockedTitles) {
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

/// Whether a generated scenario is good enough to use: complete core fields,
/// distinct roles, no leaked meta text, has a Chinese translation, and a
/// non-duplicate title.
bool isStructurallyValidScenario(
  ConversationScenario scenario, {
  List<String> blockedTitles = const [],
}) {
  if (isNearDuplicateScenarioTitle(scenario.title, blockedTitles)) return false;
  if (scenario.title.trim().isEmpty ||
      scenario.setting.trim().isEmpty ||
      scenario.aiRole.trim().isEmpty ||
      scenario.userRole.trim().isEmpty) {
    return false;
  }
  if (scenarioHasMetaText(scenario.title) ||
      scenarioHasMetaText(scenario.setting) ||
      scenarioHasMetaText(scenario.aiRole) ||
      scenarioHasMetaText(scenario.userRole) ||
      scenario.stages.any(scenarioHasMetaText)) {
    return false;
  }
  if (scenario.aiRole.trim().toLowerCase() ==
      scenario.userRole.trim().toLowerCase()) {
    return false;
  }
  final hasZh = scenarioContainsCjk(scenario.titleZh) ||
      scenarioContainsCjk(scenario.settingZh) ||
      scenarioContainsCjk(scenario.aiRoleZh) ||
      scenarioContainsCjk(scenario.userRoleZh) ||
      scenario.stagesZh.any(scenarioContainsCjk);
  return hasZh;
}
