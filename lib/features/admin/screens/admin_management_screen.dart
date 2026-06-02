import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/models/admin_account_summary.dart';
import 'package:recall_app/models/admin_community_report.dart';
import 'package:recall_app/providers/admin_provider.dart';

class AdminManagementScreen extends ConsumerStatefulWidget {
  const AdminManagementScreen({super.key});

  @override
  ConsumerState<AdminManagementScreen> createState() =>
      _AdminManagementScreenState();
}

class _AdminManagementScreenState extends ConsumerState<AdminManagementScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _refresh() {
    ref.invalidate(adminAccountsProvider(_query));
    ref.invalidate(adminAuditProvider);
    ref.invalidate(adminCommunityReportsProvider);
  }

  Future<void> _safeAction(
    Future<void> Function() action, {
    String? success,
  }) async {
    try {
      await action();
      if (!mounted) return;
      _refresh();
      if (success != null && success.isNotEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(success)));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('操作失敗：$e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final accountsAsync = ref.watch(adminAccountsProvider(_query));
    final auditAsync = ref.watch(adminAuditProvider);
    final reportsAsync = ref.watch(adminCommunityReportsProvider);
    final adminService = ref.read(adminServiceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('管理員後台'),
        actions: [
          IconButton(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '重新整理',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: '搜尋 user id 或 email',
              prefixIcon: const Icon(Icons.search_rounded),
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              suffixIcon: IconButton(
                onPressed: () {
                  setState(() => _query = _searchController.text.trim());
                },
                icon: const Icon(Icons.arrow_forward_rounded),
              ),
            ),
            onSubmitted: (_) {
              setState(() => _query = _searchController.text.trim());
            },
          ),
          const SizedBox(height: 16),
          const Text(
            '帳號管理',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
          ),
          const SizedBox(height: 8),
          accountsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('載入帳號失敗：$e'),
            data: (accounts) {
              if (accounts.isEmpty) {
                return const Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('目前沒有可顯示的帳號。\n請先讓使用者登入一次，建立 profiles 後就會出現。'),
                  ),
                );
              }
              return Column(
                children: accounts
                    .map(
                      (account) => _AccountCard(
                        account: account,
                        onSetTeacher: () => _safeAction(
                          () => adminService.setUserClassroomRole(
                            targetUserId: account.userId,
                            role: 'teacher',
                          ),
                          success: '已設為老師',
                        ),
                        onSetStudent: () => _safeAction(
                          () => adminService.setUserClassroomRole(
                            targetUserId: account.userId,
                            role: 'student',
                          ),
                          success: '已設為學生',
                        ),
                        onBlock: () => _safeAction(
                          () => adminService.blockUser(
                            targetUserId: account.userId,
                            reason: 'manual_admin_action',
                          ),
                          success: '已封鎖帳號',
                        ),
                        onUnblock: () => _safeAction(
                          () => adminService.unblockUser(
                            targetUserId: account.userId,
                            reason: 'manual_admin_action',
                          ),
                          success: '已解除封鎖',
                        ),
                        onForceSignOut: () => _safeAction(
                          () => adminService.forceSignOutAllSessions(
                            targetUserId: account.userId,
                            reason: 'manual_admin_action',
                          ),
                          success: '已加入強制登出佇列',
                        ),
                        onGrantSupportAdmin: () => _safeAction(
                          () => adminService.assignRole(
                            adminUserId: account.userId,
                            roleKey: 'support_admin',
                            scopeType: 'global',
                          ),
                          success: '已授權客服管理員',
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
          const SizedBox(height: 20),
          const Text(
            '社群檢舉審核',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
          ),
          const SizedBox(height: 8),
          reportsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('載入社群檢舉失敗：$e'),
            data: (reports) {
              if (reports.isEmpty) return const Text('目前沒有社群檢舉。');
              return Column(
                children: reports
                    .map(
                      (report) => _CommunityReportCard(
                        report: report,
                        onRestore: () => _safeAction(
                          () => adminService.resolveCommunityReports(
                            publicSetId: report.publicSetId,
                            action: 'restore',
                          ),
                          success: '已恢復公開集',
                        ),
                        onHide: () => _safeAction(
                          () => adminService.resolveCommunityReports(
                            publicSetId: report.publicSetId,
                            action: 'hide',
                          ),
                          success: '已隱藏公開集',
                        ),
                        onReject: () => _safeAction(
                          () => adminService.resolveCommunityReports(
                            publicSetId: report.publicSetId,
                            action: 'reject',
                          ),
                          success: '已拒絕並下架公開集',
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
          const SizedBox(height: 20),
          const Text(
            '稽核紀錄',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
          ),
          const SizedBox(height: 8),
          auditAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('載入稽核紀錄失敗：$e'),
            data: (logs) {
              if (logs.isEmpty) return const Text('目前沒有稽核紀錄。');
              return Column(
                children: logs
                    .take(30)
                    .map(
                      (entry) => Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          dense: true,
                          leading: const Icon(Icons.history_rounded),
                          title: Text(entry.action),
                          subtitle: Text(
                            'actor=${entry.actorUserId}\n'
                            'target=${entry.targetUserId ?? '-'}\n'
                            '${entry.reason}\n'
                            '${entry.createdAt.toLocal()}',
                          ),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CommunityReportCard extends StatelessWidget {
  const _CommunityReportCard({
    required this.report,
    required this.onRestore,
    required this.onHide,
    required this.onReject,
  });

  final AdminCommunityReport report;
  final Future<void> Function() onRestore;
  final Future<void> Function() onHide;
  final Future<void> Function() onReject;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              report.title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text('作者：${report.authorName}'),
            Text('待處理檢舉：${report.pendingReportCount}'),
            Text('顯示狀態：${report.visibility}'),
            Text('審核狀態：${report.moderationStatus}'),
            if (report.moderationReason.isNotEmpty)
              Text('原因：${report.moderationReason}'),
            if (report.latestReportAt != null)
              Text('最新檢舉：${report.latestReportAt!.toLocal()}'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(onPressed: onRestore, child: const Text('恢復公開')),
                OutlinedButton(onPressed: onHide, child: const Text('暫時隱藏')),
                FilledButton(onPressed: onReject, child: const Text('拒絕並下架')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  final AdminAccountSummary account;
  final Future<void> Function() onSetTeacher;
  final Future<void> Function() onSetStudent;
  final Future<void> Function() onBlock;
  final Future<void> Function() onUnblock;
  final Future<void> Function() onForceSignOut;
  final Future<void> Function() onGrantSupportAdmin;

  const _AccountCard({
    required this.account,
    required this.onSetTeacher,
    required this.onSetStudent,
    required this.onBlock,
    required this.onUnblock,
    required this.onForceSignOut,
    required this.onGrantSupportAdmin,
  });

  @override
  Widget build(BuildContext context) {
    final roleLabel = account.classroomRole == 'teacher' ? '老師' : '學生';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 1.4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              account.userId,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              account.email.isEmpty ? '-' : account.email,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 8),
            Text('學習集數量：${account.studySetCount}'),
            Text('最後活動：${account.lastActivityAt?.toLocal() ?? '-'}'),
            Text('封鎖狀態：${account.isBlocked ? '已封鎖' : '正常'}'),
            Text('班級角色：$roleLabel'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!account.isBlocked)
                  OutlinedButton(onPressed: onBlock, child: const Text('封鎖')),
                if (account.isBlocked)
                  OutlinedButton(
                    onPressed: onUnblock,
                    child: const Text('解除封鎖'),
                  ),
                OutlinedButton(
                  onPressed: onForceSignOut,
                  child: const Text('強制登出'),
                ),
                ElevatedButton(
                  onPressed: onGrantSupportAdmin,
                  child: const Text('授權客服管理員'),
                ),
                OutlinedButton(
                  onPressed: account.classroomRole == 'teacher'
                      ? null
                      : onSetTeacher,
                  child: const Text('設為老師'),
                ),
                OutlinedButton(
                  onPressed: account.classroomRole == 'student'
                      ? null
                      : onSetStudent,
                  child: const Text('設為學生'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
