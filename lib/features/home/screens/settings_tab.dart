import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:recall_app/core/constants/app_constants.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/core/theme/app_theme.dart';
import 'package:recall_app/core/widgets/liquid_glass.dart';
import 'package:recall_app/features/home/widgets/dashboard_helpers.dart';
import 'package:recall_app/features/home/screens/security_dialogs.dart';
import 'package:recall_app/providers/auth_provider.dart';
import 'package:recall_app/providers/admin_provider.dart';
import 'package:recall_app/providers/biometric_provider.dart';
import 'package:recall_app/providers/ai_provider_provider.dart';
import 'package:recall_app/providers/ai_runtime_provider.dart';
import 'package:recall_app/features/home/widgets/ai_usage_card.dart';
import 'package:recall_app/features/home/widgets/model_manager_card.dart';
import 'package:recall_app/providers/gemini_key_provider.dart';
import 'package:recall_app/providers/locale_provider.dart';
import 'package:recall_app/providers/notification_provider.dart';
import 'package:recall_app/providers/pomodoro_provider.dart';
import 'package:recall_app/providers/profile_provider.dart';
import 'package:recall_app/providers/sync_provider.dart';
import 'package:file_picker/file_picker.dart';

class SettingsTab extends ConsumerStatefulWidget {
  final VoidCallback onResetTab;

  const SettingsTab({super.key, required this.onResetTab});

  @override
  ConsumerState<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<SettingsTab> {
  Widget _buildProfileAvatar(BuildContext context, UserProfile? profile, dynamic user) {
    final hasAvatar = profile?.avatarUrl.isNotEmpty == true;
    final name = profile?.displayName ?? '';
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.indigo.withValues(alpha: 0.15),
            AppTheme.cyan.withValues(alpha: 0.12),
            AppTheme.purple.withValues(alpha: 0.10),
          ],
        ),
        border: Border.all(color: AppTheme.indigo.withValues(alpha: 0.12)),
      ),
      child: hasAvatar
          ? ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: Image.network(
                profile!.avatarUrl,
                fit: BoxFit.cover,
                width: 52,
                height: 52,
                errorBuilder: (_, __, ___) => _avatarFallback(context, name, user),
              ),
            )
          : _avatarFallback(context, name, user),
    );
  }

  Widget _avatarFallback(BuildContext context, String name, dynamic user) {
    if (name.isNotEmpty) {
      return Center(
        child: Text(
          name[0].toUpperCase(),
          style: GoogleFonts.notoSerifTc(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: AppTheme.indigo.withValues(alpha: 0.75),
          ),
        ),
      );
    }
    return Icon(
      user == null ? CupertinoIcons.person : CupertinoIcons.person_fill,
      color: AppTheme.indigo.withValues(alpha: 0.6),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final user = ref.watch(currentUserProvider);
    final userEmail = user?.email?.trim();
    final hasSignedInEmail = userEmail != null && userEmail.isNotEmpty;
    final reminderEnabled = ref.watch(notificationProvider);
    final biometricQuickUnlockEnabled = ref.watch(biometricQuickUnlockProvider);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final isAdmin = ref
        .watch(adminAccessProvider)
        .maybeWhen(data: (value) => value, orElse: () => false);
    final profile = ref.watch(profileProvider).valueOrNull;
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 10, 16, 28 + bottomInset),
      children: [
        // -- User card --
        AdaptiveSettingsCard(
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () async {
              await context.push('/profile/edit');
              if (mounted) ref.invalidate(profileProvider);
            },
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.52),
                    AppTheme.indigo.withValues(alpha: 0.1),
                    AppTheme.cyan.withValues(alpha: 0.08),
                  ],
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  _buildProfileAvatar(context, profile, user),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (profile?.displayName.isNotEmpty == true)
                              ? profile!.displayName
                              : (!hasSignedInEmail
                                  ? l10n.guestMode
                                  : l10n.personalSettings),
                          style: GoogleFonts.notoSerifTc(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurface,
                            letterSpacing: 0.3,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          hasSignedInEmail ? userEmail : l10n.loginToSync,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                        if (profile?.bio.isNotEmpty == true) ...[
                          const SizedBox(height: 3),
                          Text(
                            profile!.bio,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (user == null)
                    FilledButton(
                      onPressed: () => context.push('/login'),
                      child: Text(l10n.logIn),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(
                        CupertinoIcons.chevron_right,
                        size: 16,
                        color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),

        // -- General --
        const SizedBox(height: 18),
        SettingsGroupTitle(l10n.settingsPreferences),
        AdaptiveSettingsCard(
          child: Column(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                minLeadingWidth: 24,
                leading: const Icon(CupertinoIcons.paintbrush),
                title: serifSettingTitle(context, l10n.displayAndLanguage),
                subtitle: Text(l10n.displaySubtitle),
                trailing: const Icon(CupertinoIcons.chevron_right),
                onTap: () => _showDisplaySettingsSheet(context: context, ref: ref),
              ),
              Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
              SwitchListTile.adaptive(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                secondary: const Icon(CupertinoIcons.bell),
                title: serifSettingTitle(context, l10n.dailyReviewReminder),
                value: reminderEnabled,
                onChanged: (value) {
                  ref
                      .read(notificationProvider.notifier)
                      .toggle(
                        value,
                        title: l10n.reminderTitle,
                        body: l10n.reminderBody,
                      );
                },
              ),
              Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
              SwitchListTile.adaptive(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                secondary: const Icon(CupertinoIcons.lock_shield),
                title: serifSettingTitle(context, l10n.biometricUnlock),
                value: biometricQuickUnlockEnabled,
                onChanged: user == null
                    ? null
                    : (enabled) => SecurityDialogs.toggleBiometricQuickUnlock(
                          context: context,
                          ref: ref,
                          enabled: enabled,
                        ),
              ),
            ],
          ),
        ),

        // -- Learning tools --
        const SizedBox(height: 18),
        SettingsGroupTitle(l10n.settingsLearning),
        AdaptiveSettingsCard(
          child: Column(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                minLeadingWidth: 24,
                leading: const Icon(CupertinoIcons.star),
                title: serifSettingTitle(context, l10n.achievements),
                subtitle: Text(l10n.achievementsSubtitle),
                trailing: const Icon(CupertinoIcons.chevron_right),
                onTap: () => context.push('/achievements'),
              ),
              Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                minLeadingWidth: 24,
                leading: const Icon(CupertinoIcons.folder),
                title: serifSettingTitle(context, l10n.folders),
                subtitle: Text(l10n.foldersSubtitle),
                trailing: const Icon(CupertinoIcons.chevron_right),
                onTap: () => context.push('/folders'),
              ),
              Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                minLeadingWidth: 24,
                leading: const Icon(CupertinoIcons.timer),
                title: serifSettingTitle(context, l10n.pomodoro),
                subtitle: Text(l10n.pomodoroSubtitle),
                trailing: const Icon(CupertinoIcons.chevron_right),
                onTap: () {
                  ref.read(pomodoroProvider.notifier).start();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.pomodoroStarted)),
                  );
                },
              ),
              Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                minLeadingWidth: 24,
                leading: const Icon(CupertinoIcons.sparkles),
                title: serifSettingTitle(context, l10n.aiSettings),
                subtitle: Text(
                  switch (ref.watch(aiProviderProvider)) {
                    AiProvider.groq => 'Groq (Llama 4 Scout)',
                    AiProvider.gemma => 'Gemma (on-device)',
                    AiProvider.gemini => l10n.aiSettingsSubtitle,
                  },
                ),
                trailing: const Icon(CupertinoIcons.chevron_right),
                onTap: () => _showGeminiKeyDialog(context: context, ref: ref),
              ),
            ],
          ),
        ),

        // -- Account & Security --
        const SizedBox(height: 18),
        SettingsGroupTitle(l10n.settingsAccount),
        Builder(
          builder: (context) {
            final conflictCount = ref.watch(syncConflictsProvider).length;
            final subtitle = conflictCount > 0
                ? '${l10n.securitySubtitle} \u00B7 ${l10n.nConflicts(conflictCount)}'
                : l10n.securitySubtitle;
            return AdaptiveSettingsCard(
              child: Column(
                children: [
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    minLeadingWidth: 24,
                    leading: const Icon(CupertinoIcons.shield),
                    title: serifSettingTitle(context, l10n.accountAndSecurity),
                    subtitle: Text(subtitle),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (conflictCount > 0)
                          Container(
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade100,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$conflictCount',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.orange.shade800,
                              ),
                            ),
                          ),
                        const Icon(CupertinoIcons.chevron_right),
                      ],
                    ),
                    onTap: () => SecurityDialogs.showSecuritySettingsSheet(
                      context: context,
                      ref: ref,
                      isAdmin: isAdmin,
                      onResetTab: widget.onResetTab,
                    ),
                  ),
                  if (isAdmin && user != null) ...[
                    Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      minLeadingWidth: 24,
                      leading: const Icon(Icons.admin_panel_settings_rounded),
                      title: serifSettingTitle(context, l10n.adminConsole),
                      trailing: const Icon(CupertinoIcons.chevron_right),
                      onTap: () => context.push('/admin'),
                    ),
                  ],
                ],
              ),
            );
          },
        ),

        // -- Version footer --
        const SizedBox(height: 28),
        Center(
          child: Column(
            children: [
              GestureDetector(
                onTap: () => context.push('/about'),
                child: Text(
                  '${AppConstants.appName} \u00B7 v${AppConstants.appVersion}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                    decoration: TextDecoration.underline,
                    decorationColor: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '\u2764\uFE0F ${l10n.madeWithLove}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showDisplaySettingsSheet({
    required BuildContext context,
    required WidgetRef ref,
  }) async {
    final l10n = AppLocalizations.of(context);

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return _buildSettingsSheetContainer(
          context: sheetContext,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.language_rounded),
                title: serifSettingTitle(context, l10n.language),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _showLanguageMenu(context, ref),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showGeminiKeyDialog({
    required BuildContext context,
    required WidgetRef ref,
  }) async {
    final l10n = AppLocalizations.of(context);
    final currentProvider = ref.read(aiProviderProvider);
    final geminiKey = ref.read(geminiKeyProvider);
    final groqKey = ref.read(groqKeyProvider);
    final geminiController = TextEditingController(text: geminiKey);
    final groqController = TextEditingController(text: groqKey);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        var selectedProvider = currentProvider;
        var isPickingModel = false;
        // Cache the model-status future so it isn't recreated on every
        // setDialogState call (repeated MethodChannel calls caused crashes).
        var gemmaLocalModelPath = ref.read(gemmaLocalModelPathProvider);
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text(l10n.aiSettings),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // —— AI 服務 ——
                    Text(
                      l10n.aiProvider,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<AiProvider>(
                      segments: const [
                        ButtonSegment<AiProvider>(
                          value: AiProvider.gemma,
                          label: Text('本機'),
                          icon: Icon(Icons.memory_rounded, size: 16),
                        ),
                        ButtonSegment<AiProvider>(
                          value: AiProvider.gemini,
                          label: Text('Gemini'),
                          icon: Icon(Icons.auto_awesome, size: 16),
                        ),
                        ButtonSegment<AiProvider>(
                          value: AiProvider.groq,
                          label: Text('Groq'),
                          icon: Icon(Icons.bolt, size: 16),
                        ),
                      ],
                      selected: {selectedProvider},
                      onSelectionChanged: (s) =>
                          setDialogState(() => selectedProvider = s.first),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      switch (selectedProvider) {
                        AiProvider.gemma =>
                          '裝置本機 AI — 免費、離線、隱私（需先下載模型）',
                        AiProvider.gemini => '雲端 AI — 速度快、品質好（需 API 金鑰）',
                        AiProvider.groq => '免費雲端 AI（需 API 金鑰）',
                      },
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // —— 服務專屬設定 ——
                    if (selectedProvider == AiProvider.gemma)
                      const ModelManagerCard(),
                    if (selectedProvider == AiProvider.gemini)
                      TextField(
                        controller: geminiController,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: l10n.geminiApiKey,
                          hintText: l10n.geminiApiKeyHint,
                          isDense: true,
                        ),
                      ),
                    if (selectedProvider == AiProvider.groq)
                      TextField(
                        controller: groqController,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: l10n.groqApiKey,
                          hintText: l10n.groqApiKeyHint,
                          isDense: true,
                        ),
                      ),

                    const Divider(height: 28),

                    // —— 隱私模式 ——
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.shield_outlined),
                      title: const Text('隱私模式'),
                      subtitle: const Text('只用裝置本機 AI，資料不傳雲端'),
                      value: ref.read(aiPrivacyModeProvider),
                      onChanged: (v) async {
                        await ref
                            .read(aiPrivacyModeProvider.notifier)
                            .setEnabled(v);
                        setDialogState(() {});
                      },
                    ),

                    const Divider(height: 28),

                    // —— AI 用量與方案（成本閘門 §2.6）——
                    const AiUsageCard(),

                    // —— 進階：手動匯入（僅本機）——
                    if (selectedProvider == AiProvider.gemma)
                      Theme(
                        data: Theme.of(
                          context,
                        ).copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(bottom: 8),
                          title: Text(
                            '進階：手動匯入模型檔',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '若你有自己的 .litertlm / .task 檔可手動匯入；一般用上方下載即可。',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: isPickingModel
                                        ? null
                                        : () async {
                                            setDialogState(
                                              () => isPickingModel = true,
                                            );
                                            final messenger =
                                                ScaffoldMessenger.of(context);
                                            try {
                                              final result = await FilePicker
                                                  .platform
                                                  .pickFiles(
                                                    allowMultiple: false,
                                                    type: FileType.any,
                                                    withData: false,
                                                  );
                                              final path =
                                                  result?.files.single.path;
                                              if (path == null ||
                                                  path.isEmpty) {
                                                return;
                                              }
                                              // Basic format sanity check —
                                              // LiteRT-LM only loads .litertlm
                                              // / .task files.
                                              final lower = path.toLowerCase();
                                              if (!lower.endsWith(
                                                    '.litertlm',
                                                  ) &&
                                                  !lower.endsWith('.task')) {
                                                messenger.showSnackBar(
                                                  const SnackBar(
                                                    content: Text(
                                                      '請選擇 .litertlm 或 .task 模型檔',
                                                    ),
                                                  ),
                                                );
                                                return;
                                              }
                                              if (!ctx.mounted) return;
                                              await ref
                                                  .read(
                                                    gemmaLocalModelPathProvider
                                                        .notifier,
                                                  )
                                                  .setPath(path);
                                              if (!ctx.mounted) return;
                                              setDialogState(
                                                () =>
                                                    gemmaLocalModelPath = path,
                                              );
                                              messenger.showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    '已設定模型：${path.split('/').last}',
                                                  ),
                                                ),
                                              );
                                            } catch (e) {
                                              if (!context.mounted) return;
                                              if (!e.toString().contains(
                                                'already_active',
                                              )) {
                                                messenger.showSnackBar(
                                                  SnackBar(
                                                    content: Text('匯入失敗：$e'),
                                                  ),
                                                );
                                              }
                                            } finally {
                                              if (ctx.mounted) {
                                                setDialogState(
                                                  () => isPickingModel = false,
                                                );
                                              }
                                            }
                                          },
                                    icon: const Icon(
                                      Icons.upload_file_rounded,
                                      size: 18,
                                    ),
                                    label: Text(
                                      gemmaLocalModelPath.trim().isEmpty
                                          ? '匯入檔案'
                                          : '更換檔案',
                                    ),
                                  ),
                                  if (gemmaLocalModelPath.trim().isNotEmpty)
                                    OutlinedButton.icon(
                                      onPressed: () async {
                                        await ref
                                            .read(
                                              gemmaLocalModelPathProvider
                                                  .notifier,
                                            )
                                            .clear();
                                        if (!ctx.mounted) return;
                                        setDialogState(
                                          () => gemmaLocalModelPath = '',
                                        );
                                      },
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                        size: 18,
                                      ),
                                      label: const Text('移除'),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                    const Divider(height: 28),
                    const TtsEnginePicker(),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(l10n.cancel),
                ),
                FilledButton(
                  onPressed: () {
                    ref
                        .read(aiProviderProvider.notifier)
                        .setProvider(selectedProvider);
                    if (selectedProvider == AiProvider.gemini) {
                      ref
                          .read(geminiKeyProvider.notifier)
                          .setApiKey(geminiController.text.trim());
                    } else if (selectedProvider == AiProvider.groq) {
                      ref
                          .read(groqKeyProvider.notifier)
                          .setApiKey(groqController.text.trim());
                    }
                    Navigator.pop(dialogContext);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.geminiApiKeySaved)),
                    );
                  },
                  child: Text(l10n.save),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSettingsSheetContainer({
    required BuildContext context,
    required Widget child,
  }) {
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: child,
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: isLiquidGlassSupported
            ? LiquidGlass(
                borderRadius: 24,
                blurSigma: 22,
                tintColor: Colors.white.withValues(alpha: 0.26),
                child: content,
              )
            : Container(
                decoration: AppTheme.softCardDecoration(
                  fillColor: Theme.of(context).colorScheme.surface,
                  borderRadius: 24,
                  elevation: 1.2,
                ),
                child: content,
              ),
      ),
    );
  }

  void _showLanguageMenu(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.language),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(l10n.chinese),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              onTap: () {
                ref
                    .read(localeProvider.notifier)
                    .setLocale(const Locale('zh', 'TW'));
                Navigator.pop(context);
              },
            ),
            ListTile(
              title: Text(l10n.english),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              onTap: () {
                ref
                    .read(localeProvider.notifier)
                    .setLocale(const Locale('en', 'US'));
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

